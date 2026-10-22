///|
/// 预签名直传凭证的签发/验签器。token 是 `Signer.dumps` 签出的
/// 自包含凭证（载荷里带绝对过期时间 `exp`），验签侧只需比较时钟。
/// presigned URL 是站点相对路径 `<url_prefix>/put/<token>` 与
/// `<url_prefix>/get/<token>`，由 `mount_routes` 挂出的路由消费。
pub struct Presigner {
  url_prefix : String
  signer : @signing.Signer
  now : () -> Int64
  default_expires : Int64
}

///|
/// `token` 载荷解码后的直传凭证内容（`exp` 已在验签时比较过，不保留）。
priv struct Claims {
  key : String
  content_type : String?
  max_size : Int64?
  download_name : String?
}

///|
/// 创建 Presigner；构造参数与 `CasFileStore::new` 的同名参数一致。
///
/// - `key`：签名密钥，泄漏等于可任意伪造上传/下载凭证。
/// - `url_prefix`：直传路由前缀，同时是 presigned URL 的前缀。
/// - `default_expires`：`presign_*` 未传 `expires` 时的默认有效期（秒）。
/// - `now`：当前 unix 秒，测试可注入固定/可变时钟。
pub fn Presigner::new(
  key~ : String,
  url_prefix~ : String = "/_files",
  default_expires~ : Int64 = 3600,
  now~ : () -> Int64 = () => @env.now().reinterpret_as_int64() / 1000,
) -> Presigner {
  Presigner::{
    url_prefix,
    signer: @signing.Signer::Signer(key~, salt="xziheng.moondark.files", now=() => {
      now().reinterpret_as_uint64()
    }),
    now,
    default_expires,
  }
}

///|
/// 签发直传上传凭证。`key` 必须是合法的相对存储路径，
/// 否则抛 `InvalidKey`。`expires` 为凭证有效期（秒），`None` 时
/// 后端缺省值生效；`content_type`/`max_size` 是对上传的约束声明，
/// 由直传路由在上传时校验。
pub fn Presigner::presign_put(
  self : Presigner,
  key~ : String,
  expires~ : Int64?,
  content_type~ : String?,
  max_size~ : Int64?,
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
/// 签发带有效期的临时下载 URL。不检查 `key` 是否存在
/// （与 S3 presigned GET 一致：URL 有效与否和对象是否存在无关）。
/// `download_name` 让下载方以指定文件名保存（Content-Disposition）。
pub fn Presigner::presign_get(
  self : Presigner,
  key~ : String,
  expires~ : Int64?,
  download_name~ : String?,
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
/// 签发 `presign_put` / `presign_get` 共用的自包含凭证：
/// 载荷里带绝对过期时间 `exp`，路由侧 `loads` 验签后只需比较时钟。
fn Presigner::mint_token(
  self : Presigner,
  claims : Map[String, Json],
  expires : Int64?,
) -> (String, Int64) {
  let expires = expires.unwrap_or(self.default_expires)
  let exp = (self.now)() + expires
  claims["exp"] = Json::number(exp.to_double())
  (self.signer.dumps(Json::object(claims)), exp)
}

///|
/// 验签并解出 `:token` 载荷：签名无效、载荷损坏、凭证用途 `m`
/// 不匹配或已过期统一返回 `None`（路由侧一律映射 403）。
/// 载荷里的 `k` 仍再过一遍 `check_key` 做纵深防御。
fn Presigner::verify(
  self : Presigner,
  req : @moonback.Request,
  want : String,
) -> Claims? {
  guard req.params.get("token") is Some(token) else { return None }
  let payload = self.signer.loads(token.to_owned()) catch { _ => return None }
  guard payload is Object(obj) else { return None }
  guard obj.get("m") is Some(String(m)) && m == want else { return None }
  guard obj.get("k") is Some(String(key)) else { return None }
  guard obj.get("exp") is Some(Number(exp, ..)) else { return None }
  guard (self.now)() <= exp.to_int64() else { return None }
  check_key(key) catch {
    _ => return None
  }
  Some(Claims::{
    key,
    content_type: match obj.get("ct") {
      Some(String(ct)) => Some(ct)
      _ => None
    },
    max_size: match obj.get("ms") {
      Some(Number(ms, ..)) => Some(ms.to_int64())
      _ => None
    },
    download_name: match obj.get("dn") {
      Some(String(dn)) => Some(dn)
      _ => None
    },
  })
}
