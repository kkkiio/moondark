///|
/// CSRF 跨源请求校验与配置错误。
pub(all) suberror CsrfError {
  /// 传入的受信任源格式非法（必须为 `"scheme://host[:port]"` 且不含路径、查询或片段）
  InvalidOrigin(String)
  /// `Sec-Fetch-Site` 表明请求来自跨站或非同源站点，且未命中 `trusted_origins`
  CrossOriginWrite
  /// 无 `Sec-Fetch-Site` 时，`Origin` 请求头与 `Host` 不匹配且未命中 `trusted_origins`
  OriginMismatch
} derive(Debug, Eq)

///|
pub extend CsrfError with Debug::{to_repr}

///|
pub extend CsrfError with Eq::{equal, not_equal}

///|
/// 基于 Fetch Metadata（`Sec-Fetch-Site`）与 `Origin` 请求头的无状态 CSRF 防护器，
/// 设计对齐 Go 1.25 `net/http.CrossOriginProtection`。
pub struct CrossOriginProtection {
  priv trusted_origins : Map[String, Bool]
  priv deny_handler : @moonback.Handler
}

///|
/// 创建 CSRF 防护中间件，拦截跨源非安全方法请求。
///
/// 内部构造 `CrossOriginProtection` 并返回其 `.middleware()`。
pub fn middleware(
  trusted_origins~ : ArrayView[String] = [],
  deny_handler~ : @moonback.Handler = (_, res) => {
    res.send_text("Forbidden (CSRF check failed)", status=403)
  },
) -> @moonback.Middleware raise CsrfError {
  CrossOriginProtection::CrossOriginProtection(trusted_origins~, deny_handler~).middleware()
}

///|
/// 构造 `CrossOriginProtection` 实例。
///
/// - `trusted_origins`：允许发起跨源写请求的源列表，每个元素必须为合法的
///   `"scheme://host[:port]"` 格式（不含 userinfo `@`、路径 `/`、查询 `?`、片段 `#`、空白字符或尾部斜杠），
///   否则抛出 `InvalidOrigin`。
/// - `deny_handler`：校验失败时的拒绝响应处理器，默认返回 403 `"Forbidden (CSRF check failed)"`。
pub fn CrossOriginProtection::CrossOriginProtection(
  trusted_origins~ : ArrayView[String] = [],
  deny_handler~ : @moonback.Handler = (_, res) => {
    res.send_text("Forbidden (CSRF check failed)", status=403)
  },
) -> CrossOriginProtection raise CsrfError {
  let trusted : Map[String, Bool] = Map([])
  for origin in trusted_origins {
    guard origin.find("://") is Some(idx) && idx > 0 else {
      raise InvalidOrigin(origin)
    }
    let scheme = origin[:idx]
    let host = origin[idx + 3:]
    let valid_scheme = scheme
      .iter()
      .all(c => c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '+' | '-' | '.'))
    let valid_host = !host.is_empty() &&
      host
      .iter()
      .all(c => !(c is ('/' | '?' | '#' | '@' | ' ' | '\t' | '\r' | '\n')))
    if !valid_scheme || !valid_host {
      raise InvalidOrigin(origin)
    }
    trusted[origin] = true
  }
  CrossOriginProtection::{ trusted_origins: trusted, deny_handler, }
}

///|
/// 将 `CrossOriginProtection` 包装为 `@moonback.Middleware`。
///
/// 对每个进入的请求调用 `self.check(req)`：校验通过则放行至 `next(req, res)`，
/// 若抛出 `CsrfError` 则交由 `deny_handler` 响应。
pub fn CrossOriginProtection::middleware(
  self : CrossOriginProtection,
) -> @moonback.Middleware {
  @moonback.Middleware(next => {
    (req, res) => {
      self.check(req) catch {
        _ => return (self.deny_handler)(req, res)
      }
      next(req, res)
    }
  })
}

///|
/// 校验单个请求是否符合跨源安全要求（对齐 Go `net/http.CrossOriginProtection.Check`）：
///
/// 1. 安全方法（`GET`、`HEAD`、`OPTIONS`）直接放行。
/// 2. 若存在 `Sec-Fetch-Site` 请求头：
///    - `"same-origin"` 或 `"none"` 直接放行；
///    - 其他值（如 `"cross-site"`、`"same-site"`）仅当 `Origin` 命中 `trusted_origins` 时放行，
///      否则抛出 `CrossOriginWrite`。
/// 3. 若无 `Sec-Fetch-Site` 请求头，回退检查 `Origin` 请求头：
///    - 无 `Origin` 头时视为同源或非浏览器请求（如 curl/CLI），直接放行；
///    - 有 `Origin` 头时，若其 `host[:port]` 与 `Host` 头完全一致，或命中 `trusted_origins` 则放行，
///      否则抛出 `OriginMismatch`。
pub fn CrossOriginProtection::check(
  self : CrossOriginProtection,
  req : @moonback.Request,
) -> Unit raise CsrfError {
  if req.meth is (@http.RequestMethod::Get | Head | Options) {
    return ()
  }
  if req.headers.get("sec-fetch-site") is Some(sec_fetch_site) {
    if sec_fetch_site is ("same-origin" | "none") {
      return ()
    }
    match req.headers.get("origin") {
      Some(origin) if self.trusted_origins.contains(origin.to_owned()) =>
        return ()
      _ => raise CrossOriginWrite
    }
  }
  match req.headers.get("origin") {
    None => ()
    Some(origin) => {
      if origin.find("://") is Some(idx) && idx > 0 {
        let origin_host = origin[idx + 3:]
        if req.headers.get("host") is Some(host) &&
          !host.is_empty() &&
          host == origin_host {
          return ()
        }
      }
      if self.trusted_origins.contains(origin.to_owned()) {
        return ()
      }
      raise OriginMismatch
    }
  }
}
