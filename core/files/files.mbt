///|
/// 文件/附件存储后端抽象，核心能力是把预签名 URL（Presigned URL）
/// 作为一等公民：前端直传对象存储（S3/R2）或框架自带的直传路由，
/// 后端不中转文件字节流，换后端时前端上传代码不需要改动。
///
/// - `presign_put`：签发带有效期的临时上传凭证（URL、HTTP Method、
///   大小/类型约束），前端直接 `fetch(url, { method, headers, body })` 上传。
/// - `presign_get`：为私有文件签发带有效期的临时下载 URL，鉴权通过后
///   无需后端中转文件流即可安全分发。
/// - `put`/`get`/`exists`/`delete`：后端直接读写的小文件路径，
///   也是 `filestest` conformance suite 的验证对象。
pub(open) trait FileStore {
  /// 签发直传上传凭证。`key` 必须是合法的相对存储路径，
  /// 否则抛 `InvalidKey`。`expires` 为凭证有效期（秒），不传时
  /// 后端缺省值生效；`content_type`/`max_size` 是对上传的约束声明，
  /// 由后端在上传时校验。
  fn presign_put(
    Self,
    key~ : String,
    expires? : Int64,
    content_type? : String,
    max_size? : Int64,
  ) -> PresignedUpload raise FileError
  /// 签发带有效期的临时下载 URL。不检查 `key` 是否存在
  /// （与 S3 presigned GET 一致：URL 有效与否和对象是否存在无关）。
  /// `download_name` 让下载方以指定文件名保存（Content-Disposition）。
  fn presign_get(Self, key~ : String, expires? : Int64, download_name? : String) -> String raise FileError
  /// 后端直写整个对象；`content_type` 由后端自行决定是否持久化。
  async fn put(Self, key~ : String, data : &@io.Data, content_type? : String) -> Unit
  /// 读取整个对象；不存在抛 `NotFound`。
  async fn get(Self, key~ : String) -> &@io.Data
  async fn exists(Self, key~ : String) -> Bool
  /// 删除对象；key 不存在时是 no-op。
  async fn delete(Self, key~ : String) -> Unit
}

///|
/// 前端直传的上传凭证。`url` 对本地后端是站点相对路径，
/// 对 S3 等对象存储是绝对 URL；前端一律按 `meth`/`headers` 直传即可。
pub(all) struct PresignedUpload {
  url : String
  meth : @http.RequestMethod
  headers : Map[String, String]
  /// 凭证过期时间（unix 秒）。
  expires_at : Int64
}

///|
/// 本地字节通道：直传路由与具体存储解耦的窄接口。路由只依赖
/// 这两个方法——上传把 body 流式落盘，下载返回已打开的文件句柄；
/// `CasFileStore` 之外的本地后端（内存、临时目录等）也可复用同一套路由。
pub(open) trait LocalStore {
  /// body 流式上传为 `key` 对应的对象；字节数超 `max_size` 时
  /// 中断并抛 `TooLarge`（不完整的内容不得对 `key` 可见）。
  async fn upload_stream(
    Self,
    key~ : String,
    content_type~ : String?,
    max_size~ : Int64?,
    reader : &@io.Reader,
  ) -> Unit
  /// 打开 `key` 对应的对象读取；不存在返回 `None`。
  async fn download(Self, key~ : String) -> Download?
}

///|
/// `LocalStore::download` 的返回：已打开的读句柄与响应元数据。
/// `file` 的所有权移交调用方，调用方负责 `close()`。
pub(all) struct Download {
  content_type : String?
  size : Int64
  file : @fs.File
}

///|
pub(all) suberror FileError {
  /// `key` 不是合法的相对存储路径。
  InvalidKey(key~ : String)
  /// 对象不存在。
  NotFound(key~ : String)
  /// 上传字节数超出 `max_size` 约束。
  TooLarge(key~ : String)
} derive(Debug, Eq)

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
pub extend FileError with Debug::{to_repr}

///|
pub extend FileError with Eq::{equal, not_equal}
