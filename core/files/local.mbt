///|
/// 本地磁盘后端。对象内容放在 `<root>/objects/<enc(key)>`，对象的
/// `Content-Type` 元数据放在 `<root>/meta/<enc(key)>`（仅在上传方声明了
/// `Content-Type` 时存在）。`enc` 是全量 percent 编码，把任意 key 拍平成
/// 单个文件名：存储树里没有中间目录，`a` 与 `a/b` 这样互为前缀的
/// key 互不干扰，key 命名空间保持扁平。
///
/// 直传闭环由 `routes()` 提供：presigned URL 是站点相对路径
/// `<url_prefix>/put/<token>` 与 `<url_prefix>/get/<token>`，
/// `token` 是 `Signer.dumps` 签出的自包含凭证（载荷里带过期时间），
/// 路由侧验签并校验过期后直接把 body 流式落盘 / 把文件流式写出。
/// `commit_lock` 串行化对象+meta 的提交，保证并发写同一 key 时
/// 数据与 Content-Type 不会错配。
struct LocalFileStore {
  root : String
  url_prefix : String
  signer : @signing.Signer
  now : () -> Int64
  default_expires : Int64
  commit_lock : @async.Mutex
}

///|
/// 创建本地磁盘后端；`root` 及其子目录不存在时自动创建。
///
/// - `key`：签名密钥，泄漏等于可任意伪造上传/下载凭证。
/// - `url_prefix`：`module()` 挂载的路由前缀，同时是 presigned URL 的前缀。
/// - `default_expires`：`presign_*` 未传 `expires` 时的默认有效期（秒）。
/// - `now`：当前 unix 秒，测试可注入固定/可变时钟。
pub async fn LocalFileStore::LocalFileStore(
  root~ : String,
  key~ : String,
  url_prefix~ : String = "/_files",
  default_expires~ : Int64 = 3600,
  now~ : () -> Int64 = () => @env.now().reinterpret_as_int64() / 1000,
) -> LocalFileStore {
  @fs.mkdir("\{root}/objects", recursive=true, allow_exist=true)
  @fs.mkdir("\{root}/meta", recursive=true, allow_exist=true)
  LocalFileStore::{
    root,
    url_prefix,
    signer: @signing.Signer::Signer(key~, salt="xziheng.moondark.files", now=() => {
      now().reinterpret_as_uint64()
    }),
    now,
    default_expires,
    commit_lock: @async.Mutex::Mutex(),
  }
}

///|
/// 校验 `key` 是相对 root 的安全路径：非空、不以 `/` 开头、
/// 不含 `\` 和 NUL、每个 `/` 分段都不是空串 / `.` / `..`。
fn check_key(key : String) -> Unit raise FileError {
  let bad = key.is_empty() ||
    key.has_prefix("/") ||
    key.contains("\\") ||
    key.contains("\u0000") ||
    key.split("/").any(seg => seg is ("" | "." | ".."))
  if bad {
    raise InvalidKey(key~)
  }
}

///|
/// 对象/元数据的路径：key 经全量 percent 编码后是单个文件名
/// （`/`、`.`、非 ASCII 等全部转义），存储目录完全扁平。
fn LocalFileStore::obj_path(self : LocalFileStore, key : String) -> String {
  "\{self.root}/objects/\{@percent.encode(key)}"
}

///|
fn LocalFileStore::meta_path(self : LocalFileStore, key : String) -> String {
  "\{self.root}/meta/\{@percent.encode(key)}"
}

///|
/// 用 `content_type` 写 meta 文件；`None` 时清掉旧 meta，
/// 保证 `put`/`handle_put` 的覆盖语义不会让旧 Content-Type 残留。
async fn LocalFileStore::write_meta(
  self : LocalFileStore,
  key : String,
  content_type : String?,
) -> Unit {
  let path = self.meta_path(key)
  match content_type {
    Some(ct) => @fs.write_file(path, ct)
    None => if @fs.exists(path) { @fs.remove(path) }
  }
}

///|
async fn LocalFileStore::read_meta(
  self : LocalFileStore,
  key : String,
) -> String? {
  let path = self.meta_path(key)
  if @fs.exists(path) {
    Some(@fs.read_file(path).text()) catch {
      _ => None
    }
  } else {
    None
  }
}

///|
/// 签发 `presign_put` / `presign_get` 共用的自包含凭证：
/// 载荷里带绝对过期时间 `exp`，路由侧 `loads` 验签后只需比较时钟。
fn LocalFileStore::mint_token(
  self : LocalFileStore,
  claims : Map[String, Json],
  expires : Int64?,
) -> (String, Int64) {
  let expires = expires.unwrap_or(self.default_expires)
  let exp = (self.now)() + expires
  claims["exp"] = Json::number(exp.to_double())
  (self.signer.dumps(Json::object(claims)), exp)
}

///|
pub impl FileStore for LocalFileStore with fn presign_put(
  self,
  key~,
  expires?,
  content_type?,
  max_size?,
) -> PresignedUpload raise FileError {
  check_key(key)
  let claims : Map[String, Json] = { "m": "put", "k": key }
  if content_type is Some(ct) {
    claims["ct"] = Json::string(ct)
  }
  if max_size is Some(ms) {
    claims["ms"] = Json::number(ms.to_double())
  }
  let (token, exp) = self.mint_token(claims, expires)
  PresignedUpload::{
    url: "\{self.url_prefix}/put/\{token}",
    meth: @http.RequestMethod::Put,
    headers: content_type.map(ct => { "Content-Type": ct }).unwrap_or({}),
    expires_at: exp,
  }
}

///|
pub impl FileStore for LocalFileStore with fn presign_get(
  self,
  key~,
  expires?,
  download_name?,
) -> String raise FileError {
  check_key(key)
  let claims : Map[String, Json] = { "m": "get", "k": key }
  if download_name is Some(dn) {
    claims["dn"] = Json::string(dn)
  }
  let (token, _exp) = self.mint_token(claims, expires)
  "\{self.url_prefix}/get/\{token}"
}

///|
pub impl FileStore for LocalFileStore with fn put(
  self,
  key~,
  data,
  content_type?,
) -> Unit raise {
  check_key(key)
  self.commit_lock.acquire()
  defer self.commit_lock.release()
  @fs.write_file(self.obj_path(key), data)
  self.write_meta(key, content_type)
}

///|
pub impl FileStore for LocalFileStore with fn get(self, key~) -> &@io.Data raise {
  check_key(key)
  let path = self.obj_path(key)
  if !@fs.exists(path) {
    raise NotFound(key~)
  }
  @fs.read_file(path) catch {
    _ => raise NotFound(key~)
  }
}

///|
pub impl FileStore for LocalFileStore with fn exists(self, key~) -> Bool raise {
  check_key(key)
  @fs.exists(self.obj_path(key))
}

///|
pub impl FileStore for LocalFileStore with fn delete(self, key~) -> Unit raise {
  check_key(key)
  self.commit_lock.acquire()
  defer self.commit_lock.release()
  for path in [self.obj_path(key), self.meta_path(key)] {
    if @fs.exists(path) {
      @fs.remove(path)
    }
  }
}

///|
pub extend LocalFileStore with FileStore::{
  presign_put,
  presign_get,
  put,
  get,
  exists,
  delete,
}
