///|
/// 内容寻址（CAS）的本地文件后端。对象字节按 sha256 存在
/// `<root>/blobs/<hash[:2]>/<hash>`（相同内容天然 dedup，落位幂等），
/// 逻辑 key 到 blob 的映射由 `Catalog` 维护。上传先把 body 流式写进
/// `<root>/staging/` 下的随机临时文件并流式算 hash，字节完整落盘、
/// rename 归档 blob 之后，`catalog.upsert` 单行翻转指针——这就是
/// 原子提交点；失败/断连只留孤儿 staging/blob 文件，不会损坏
/// 已存在的对象，数据与 Content-Type 也不会错配，因此不需要
/// `commit_lock`。
///
/// 不做 blob GC：`delete` 只 `catalog.remove`，覆盖产生的旧 blob
/// 变孤儿，留给未来的 mark-sweep GC（catalog 是唯一事实源，blob
/// 不做引用计数）。
pub struct CasFileStore {
  root : String
  blobs : String
  catalog : &Catalog
  presigner : Presigner
}

///|
/// 创建本地 CAS 后端；`<root>/blobs` 与 `<root>/staging` 不存在时
/// 自动创建。`key`/`url_prefix`/`default_expires`/`now` 透传给内嵌的
/// `Presigner`（`key` 泄漏等于可任意伪造上传/下载凭证）。
pub async fn CasFileStore::new(
  root~ : String,
  catalog~ : &Catalog,
  key~ : String,
  url_prefix~ : String = "/_files",
  default_expires~ : Int64 = 3600,
  now~ : () -> Int64 = () => @env.now().reinterpret_as_int64() / 1000,
) -> CasFileStore {
  @fs.mkdir("\{root}/blobs", recursive=true, allow_exist=true)
  @fs.mkdir("\{root}/staging", recursive=true, allow_exist=true)
  CasFileStore::{
    root,
    blobs: "\{root}/blobs",
    catalog,
    presigner: Presigner::new(key~, url_prefix~, default_expires~, now~),
  }
}

///|
/// blob 落盘路径：`<blobs>/<hash[:2]>/<hash>`，前两位分桶防止
/// 单层目录过大（`hash` 恒为 sha256 hex，ASCII 内无代理对问题）。
fn CasFileStore::blob_path(self : CasFileStore, hash : String) -> String {
  "\{self.blobs}/\{hash[:2]}/\{hash}"
}

///|
/// staging 临时文件路径：随机后缀保证跨进程唯一；与 blobs 同盘，
/// 保证归档时的 rename 不跨文件系统。
fn staging_path(root : String) -> String {
  let mut name = ""
  for b in @env.rand(8).unwrap_or(b"") {
    name += b.to_hex()
  }
  "\{root}/staging/.part-\{name}"
}

///|
/// 归档已完整落盘的 staging 文件为 blob，并提交 catalog 指针。
/// rename 覆盖与 upsert 对同 hash 幂等：并发上传相同字节时后写者
/// 覆盖同内容 blob，无副作用；并发上传同一 key 时后提交者整体覆盖。
async fn CasFileStore::commit_blob(
  self : CasFileStore,
  key~ : String,
  staging~ : String,
  hash~ : String,
  size~ : Int64,
  content_type~ : String?,
) -> Unit {
  let dir = "\{self.blobs}/\{hash[:2]}"
  @fs.mkdir(dir, recursive=true, allow_exist=true)
  @fs.rename(staging, "\{dir}/\{hash}")
  self.catalog.upsert(key~, entry=CatalogEntry::{ hash, size, content_type, })
}

///|
pub impl FileStore for CasFileStore with fn presign_put(
  self,
  key~,
  expires?,
  content_type?,
  max_size?,
) -> PresignedUpload raise FileError {
  self.presigner.presign_put(key~, expires~, content_type~, max_size~)
}

///|
pub impl FileStore for CasFileStore with fn presign_get(
  self,
  key~,
  expires?,
  download_name?,
) -> String raise FileError {
  self.presigner.presign_get(key~, expires~, download_name~)
}

///|
/// 后端直写整个对象：与 `upload_stream` 同一套 CAS 提交流程，
/// 只是输入已在内存，一次性算 hash 即可。
pub impl FileStore for CasFileStore with fn put(self, key~, data, content_type?) -> Unit raise {
  check_key(key)
  let bytes = data.binary()
  let hash = @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
  let tmp = staging_path(self.root)
  @fs.write_file(tmp, bytes)
  self.commit_blob(
    key~,
    staging=tmp,
    hash~,
    size=bytes.length().to_int64(),
    content_type~,
  )
}

///|
/// 读取整个对象；catalog 未登记或 blob 缺失都抛 `NotFound`
/// （blob 缺失意味着磁盘被外部破坏，语义上视同对象不存在）。
pub impl FileStore for CasFileStore with fn get(self, key~) -> &@io.Data raise {
  check_key(key)
  guard self.catalog.lookup(key~) is Some(entry) else { raise NotFound(key~) }
  @fs.read_file(self.blob_path(entry.hash)) catch {
    _ => raise NotFound(key~)
  }
}

///|
pub impl FileStore for CasFileStore with fn exists(self, key~) -> Bool raise {
  check_key(key)
  self.catalog.lookup(key~) is Some(_)
}

///|
/// 删除对象：只摘 catalog 指针（原子、no-op 于缺失 key）。
/// 旧 blob 变孤儿，留给未来的 mark-sweep GC。
pub impl FileStore for CasFileStore with fn delete(self, key~) -> Unit raise {
  check_key(key)
  self.catalog.remove(key~)
}

///|
/// 直传上传的 CAS 实现：body 流式写 staging 并同步算 sha256，
/// 超 `max_size` 立即中断（`errdefer` 清理临时文件）抛 `TooLarge`；
/// 收完后归档 blob 并 upsert catalog——指针翻转即原子提交。
pub impl LocalStore for CasFileStore with fn upload_stream(
  self,
  key~,
  content_type~,
  max_size~,
  reader,
) -> Unit raise {
  check_key(key)
  let tmp = staging_path(self.root)
  let file = @fs.open(tmp, mode=@fs.WriteOnly, create_mode=@fs.CreateOrTruncate)
  let hasher = @crypto.SHA256::new()
  let mut total = 0L
  {
    errdefer {
      file.close()
      @fs.remove(tmp) catch {
        _ => ()
      }
    }
    while reader.read_some(max_len=64 * 1024) is Some(chunk) {
      total += chunk.length().to_int64()
      if max_size is Some(ms) && total > ms {
        raise TooLarge(key~)
      }
      hasher.update(chunk)
      file.write(chunk)
    }
  }
  file.close()
  let hash = @crypto.bytes_to_hex_string(hasher.finalize())
  self.commit_blob(key~, staging=tmp, hash~, size=total, content_type~)
}

///|
/// 直传下载的 CAS 实现：catalog 查指针 → 打开 blob 文件返回；
/// 指针缺失或 blob 文件缺失都返回 `None`。
pub impl LocalStore for CasFileStore with fn download(self, key~) -> Download? raise {
  check_key(key)
  guard self.catalog.lookup(key~) is Some(entry) else { return None }
  let path = self.blob_path(entry.hash)
  if !@fs.exists(path) {
    return None
  }
  let file = @fs.open(path, mode=@fs.ReadOnly)
  Some(Download::{ content_type: entry.content_type, size: entry.size, file, })
}

///|
pub extend CasFileStore with FileStore::{
  presign_put,
  presign_get,
  put,
  get,
  exists,
  delete,
}

///|
pub extend CasFileStore with LocalStore::{upload_stream, download}
