///|
/// Query-string logging policy for `middleware`: presign tokens, OAuth
/// `code`/`state` and other credentials routinely travel in `?query`,
/// so values are redacted Rails-`filter_parameters`-style by default.
pub(all) enum QueryLog {
  /// Log `url.query` with `redact` matches replaced by `[FILTERED]`
  /// (case-insensitive substring match on the parameter name).
  Full(redact~ : Array[String])
  /// Omit the query string entirely.
  None
} derive(Debug)

///|
pub extend QueryLog with Debug::{to_repr}

///|
/// Default denylist for `QueryLog::Full` — credentials and single-use
/// tokens that must never reach a log backend.
pub let default_query_redact : Array[String] = [
  "password", "token", "secret", "signature", "sig", "key", "code", "state", "credential",
  "authorization",
]

///|
/// Access-log + error-log middleware: register **first** (outermost) so
/// it also catches errors raised by the other middlewares downstream.
///
/// - success: one `info` entry per request with OTel HTTP semconv fields
///   (`http.request.method`, `url.path`, `http.response.status_code`,
///   `http.server.request.duration` seconds, `client.address`,
///   `user_agent.original`, plus `url.query` per the `query` policy);
///   a completed 5xx response logs at `error` even without a raise —
///   a handler answering 500 is a server failure either way;
/// - raise: one `error` entry carrying the propagated error, then
///   re-raises so moonback's `handle_request` still answers the bare
///   500 — the error would otherwise be swallowed unobserved
///   (moonbitlang/moonback#7). `status_code` 0 means the handler never
///   started writing a response.
///
/// `moonback` exposes no route template, so `url.path` is the concrete
/// path — beware cardinality on id-bearing routes. Presigned file URLs
/// put a capability token in the last path segment; `path_redact`
/// lists prefixes whose final segment logs as `[FILTERED]` and
/// defaults to the files module's presign prefix. Keep it in sync
/// when `Presigner` is built with a custom `url_prefix`.
pub fn middleware(
  category~ : String = "moondark.http",
  query~ : QueryLog = Full(redact=default_query_redact),
  path_redact~ : Array[String] = ["/_files"],
) -> @moonback.Middleware {
  @moonback.Middleware(next => {
    (req, res) => {
      let start = @env.now()
      let mut status = 0
      let outcome : Result[Unit, Error] = Ok(
        next(req, (code, headers) => {
          status = code
          res.respond(status=code, headers~)
        }),
      ) catch {
        e => Err(e)
      }
      let duration = (@env.now() - start).reinterpret_as_int64().to_double() /
        1000.0
      let emit = (ev : @xlog.Event, error : String?) => {
        ev.write_object_begin()
        ev.write_object_field("http.request.method", method_name(req.meth))
        ev.write_object_field("url.path", redact_path(req.path, path_redact[:]))
        ev.write_object_field("http.response.status_code", status)
        ev.write_object_field("http.server.request.duration", duration)
        match query {
          Full(redact~) =>
            if req.search is Some(search) && !search.is_empty() {
              ev.write_object_field(
                "url.query",
                redact_query(req.query(), redact[:]),
              )
            }
          None => ()
        }
        if req.ip() is Some(ip) {
          ev.write_object_field("client.address", ip.to_owned())
        }
        if req.headers.get("user-agent") is Some(ua) {
          ev.write_object_field("user_agent.original", ua.to_owned())
        }
        if error is Some(e) {
          ev.write_object_field("error", e)
        }
        ev.write_object_end()
      }
      match outcome {
        Err(e) => {
          if @xlog.error(category~) is Some(ev) {
            emit(ev, Some(e.to_string()))
          }
          raise e
        }
        Ok(_) =>
          if status >= 500 {
            if @xlog.error(category~) is Some(ev) {
              emit(ev, None)
            }
          } else if @xlog.info(category~) is Some(ev) {
            emit(ev, None)
          }
      }
    }
  })
}

///|
fn method_name(meth : @http.RequestMethod) -> String {
  match meth {
    Get => "GET"
    Head => "HEAD"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Connect => "CONNECT"
    Options => "OPTIONS"
    Trace => "TRACE"
    Patch => "PATCH"
  }
}

///|
/// Paths starting with `prefix/` carry a capability token as their
/// final segment (presigned file URLs) — mask only that segment so
/// the operation (`put`/`get`) stays visible.
fn redact_path(path : StringView, prefixes : ArrayView[String]) -> String {
  for p in prefixes {
    if path.has_prefix("\{p}/") && path.rev_find("/") is Some(i) {
      return "\{path[:i]}/[FILTERED]"
    }
  }
  path.to_owned()
}

///|
/// Rebuild `k=v&...` from the **decoded** pairs: matching against
/// decoded keys keeps `%63ode=abc` from slipping `code` past the
/// denylist. Log-only rendering — decoded values may contain `&`.
fn redact_query(
  params : @moonback.QueryParams,
  deny : ArrayView[String],
) -> String {
  let out = StringBuilder()
  let mut first = true
  for pair in params.iter() {
    let (key, value) = pair
    if !first {
      out.write_char('&')
    }
    first = false
    out.write_string(key)
    out.write_char('=')
    let key_lower = key.to_lower()
    let redacted = deny.iter().any(d => key_lower.contains(d.to_lower()))
    out.write_string(if redacted { "[FILTERED]" } else { value })
  }
  out.to_string()
}
