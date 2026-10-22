///|
/// `token` 载荷解码后的直传凭证内容（`exp` 已在验签时比较过，不保留）。
priv struct Claims {
  key : String
  content_type : String?
  max_size : Int64?
  download_name : String?
}

///|
/// 挂载本地后端直传路由的 moonback `Module`：
///
/// - `PUT  <url_prefix>/put/:token` — presigned 上传，body 原样流式落盘；
/// - `GET  <url_prefix>/get/:token` — presigned 下载，文件流式写出。
///
/// 用法：`ctx.use_(store.routes())`。前端拿到的 presigned URL 与
/// S3 后端同形（`fetch(url, { method: "PUT", body: file })`），
/// 切换后端时无需改动。
pub fn LocalFileStore::routes(self : LocalFileStore) -> @moonback.Module {
  @moonback.Module(ctx => {
    ctx.add_route(@http.RequestMethod::Put, "\{self.url_prefix}/put/:token", (
      req,
      res,
    ) => self.handle_put(req, res))
    ctx.get("\{self.url_prefix}/get/:token", (req, res) => {
      self.handle_get(req, res)
    })
  })
}

///|
/// 验签并解出 `:token` 载荷：签名无效、载荷损坏、凭证用途 `m`
/// 不匹配或已过期统一返回 `None`（路由侧一律映射 403）。
/// 载荷里的 `k` 仍再过一遍 `check_key` 做纵深防御。
fn LocalFileStore::verify_token(
  self : LocalFileStore,
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

///|
/// presigned 上传：验签后先校验签名约束（`Content-Type` 与 claim 一致、
/// `Content-Length` 未超 `max_size`——声明值可能缺失或撒谎，最终以流式
/// 计数为准），再把 body 流式写入对象目录下的随机临时文件，全部收完
/// 才在 `commit_lock` 下原子 rename 覆盖目标并写 meta：
/// 失败/超限/断连只会留下孤儿临时文件，不会损坏已存在的对象，
/// 数据与 meta 也不会错配。
async fn LocalFileStore::handle_put(
  self : LocalFileStore,
  req : @moonback.Request,
  res : @moonback.Responder,
) -> Unit {
  guard self.verify_token(req, "put") is Some(claims) else {
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
  let path = self.obj_path(claims.key)
  let tmp = staging_path(self.root)
  let file = @fs.open(tmp, mode=@fs.WriteOnly, create_mode=@fs.CreateOrTruncate)
  let mut total = 0L
  let mut oversized = false
  {
    errdefer {
      file.close()
      @fs.remove(tmp) catch {
        _ => ()
      }
    }
    while reader.read_some(max_len=64 * 1024) is Some(chunk) {
      total += chunk.length().to_int64()
      if claims.max_size is Some(ms) && total > ms {
        oversized = true
        break
      }
      file.write(chunk)
    }
  }
  file.close()
  if oversized {
    @fs.remove(tmp)
    return res.send_void(status=413)
  }
  // 串行化"换对象 + 写 meta"：并发上传同一 key 时，后提交者
  // 整体覆盖前者的数据与 Content-Type，不会出现错配版本。
  let content_type = match claims.content_type {
    Some(ct) => Some(ct)
    None => req.headers.get("content-type").map(v => v.to_owned())
  }
  self.commit_lock.acquire()
  defer self.commit_lock.release()
  @fs.rename(tmp, path)
  self.write_meta(claims.key, content_type)
  res.send_void(status=200)
}

///|
/// presigned 下载：验签后按 meta 中的 `Content-Type`
/// （缺省 `application/octet-stream`）流式写出文件。
/// `download_name` 声明时附加 `Content-Disposition: attachment`。
async fn LocalFileStore::handle_get(
  self : LocalFileStore,
  req : @moonback.Request,
  res : @moonback.Responder,
) -> Unit {
  guard self.verify_token(req, "get") is Some(claims) else {
    return res.send_void(status=403)
  }
  let path = self.obj_path(claims.key)
  // 持锁读完 meta 并打开文件，保证响应对应的是同一版本的对象。
  self.commit_lock.acquire()
  let opened : (@fs.File, Map[String, String])? = {
    errdefer self.commit_lock.release()
    if !@fs.exists(path) {
      None
    } else {
      let file = @fs.open(path, mode=@fs.ReadOnly)
      let headers : Map[String, String] = {
        "Content-Type": self
        .read_meta(claims.key)
        .unwrap_or("application/octet-stream"),
        "Content-Length": file.size().to_string(),
        "X-Content-Type-Options": "nosniff",
      }
      Some((file, headers))
    }
  }
  self.commit_lock.release()
  guard opened is Some((file, headers)) else {
    return res.send_void(status=404)
  }
  defer file.close()
  if claims.download_name is Some(dn) {
    headers["Content-Disposition"] = content_disposition(dn)
  }
  res.respond(status=200, headers~).write_reader(file)
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
/// staging 临时文件路径：随机后缀保证跨进程唯一，`.part-` 前缀
/// 与 percent 编码后的对象名（只含 `[0-9A-Za-z%]`）永不冲突；
/// 与对象同目录，保证 rename 不跨文件系统。
fn staging_path(root : String) -> String {
  let mut name = ""
  for b in @env.rand(8).unwrap_or(b"") {
    name += b.to_hex()
  }
  "\{root}/objects/.part-\{name}"
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
