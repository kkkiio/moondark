///|
/// 挂载本地后端直传路由的 moonback `Module`：
///
/// - `PUT  <url_prefix>/put/:token` — presigned 上传，body 原样流式落盘；
/// - `GET  <url_prefix>/get/:token` — presigned 下载，文件流式写出。
///
/// 用法：`ctx.use_(store.routes())`。前端拿到的 presigned URL 与
/// S3 后端同形（`fetch(url, { method: "PUT", body: file })`），
/// 切换后端时无需改动。
pub fn CasFileStore::routes(self : CasFileStore) -> @moonback.Module {
  mount_routes(self, self.presigner)
}

///|
/// 直传路由的通用挂载：字节通道走 `LocalStore` 窄接口（上传流式落盘、
/// 下载返回已打开的文件），凭证签发/验签走 `Presigner`——两者解耦，
/// 任何 `LocalStore` 实现都能复用同一套路由。
pub fn mount_routes(
  store : &LocalStore,
  presigner : Presigner,
) -> @moonback.Module {
  @moonback.Module(ctx => {
    ctx.add_route(
      @http.RequestMethod::Put,
      "\{presigner.url_prefix}/put/:token",
      (req, res) => handle_put(store, presigner, req, res),
    )
    ctx.get("\{presigner.url_prefix}/get/:token", (req, res) => {
      handle_get(store, presigner, req, res)
    })
  })
}

///|
/// presigned 上传：验签后先校验签名约束（`Content-Type` 与 claim 一致、
/// `Content-Length` 未超 `max_size`——声明值可能缺失或撒谎，最终以
/// `upload_stream` 的流式计数为准），再把 body 交给 store 落盘。
/// CAS 提交天然原子（字节完整落盘后才翻转 catalog 指针），不需要
/// `commit_lock`：失败/超限/断连只会留下孤儿临时文件，不会损坏
/// 已存在的对象。
async fn handle_put(
  store : &LocalStore,
  presigner : Presigner,
  req : @moonback.Request,
  res : @moonback.Responder,
) -> Unit {
  guard presigner.verify(req, "put") is Some(claims) else {
    return res.send_void(status=403)
  }
  if claims.content_type is Some(ct) &&
    !(req.headers.get("content-type") is Some(got) && got.to_owned() == ct) {
    return res.send_void(status=403)
  }
  if claims.max_size is Some(ms) &&
    req.headers.get("content-length").bind(parse_int64) is Some(len) &&
    len > ms {
    return res.send_void(status=413)
  }
  let reader = req.body.reader() catch { _ => return res.send_void(status=400) }
  let content_type = match claims.content_type {
    Some(ct) => Some(ct)
    None => req.headers.get("content-type").map(v => v.to_owned())
  }
  store.upload_stream(
    key=claims.key,
    content_type~,
    max_size=claims.max_size,
    reader,
  ) catch {
    TooLarge(_) => return res.send_void(status=413)
    err => raise err
  }
  res.send_void(status=200)
}

///|
/// presigned 下载：验签后按 catalog 中的 `Content-Type`
/// （缺省 `application/octet-stream`）流式写出文件。
/// `download_name` 声明时附加 `Content-Disposition: attachment`。
async fn handle_get(
  store : &LocalStore,
  presigner : Presigner,
  req : @moonback.Request,
  res : @moonback.Responder,
) -> Unit {
  guard presigner.verify(req, "get") is Some(claims) else {
    return res.send_void(status=403)
  }
  guard store.download(key=claims.key) is Some(download) else {
    return res.send_void(status=404)
  }
  defer download.file.close()
  let headers : Map[String, String] = {
    "Content-Type": download.content_type.unwrap_or("application/octet-stream"),
    "Content-Length": download.size.to_string(),
    "X-Content-Type-Options": "nosniff",
  }
  if claims.download_name is Some(dn) {
    headers["Content-Disposition"] = content_disposition(dn)
  }
  res.respond(status=200, headers~).write_reader(download.file)
}

///|
/// RFC 6266 `Content-Disposition`：纯 ASCII fallback 文件名 +
/// RFC 5987 `filename*` UTF-8 percent 编码，非 ASCII 字符在
/// fallback 中折叠为 `_`。
fn content_disposition(name : String) -> String {
  let fallback = StringBuilder()
  for c in name {
    if c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '.' | '-' | '_') {
      fallback.write_char(c)
    } else {
      fallback.write_char('_')
    }
  }
  "attachment; filename=\"\{fallback}\"; filename*=UTF-8''\{@percent.encode(name)}"
}

///|
/// 非负十进制整数解析，只认 `0-9`（Content-Length 不该有别的形态）。
fn parse_int64(s : StringView) -> Int64? {
  guard !s.is_empty() else { return None }
  let mut n = 0L
  for c in s {
    guard c is ('0'..<='9') else { return None }
    n = n * 10 + (c.to_int() - '0'.to_int()).to_int64()
  }
  Some(n)
}
