///|
extenum @moonback.TypedBox += {
  Session(Session)
}

///|
let key : @moonback.TypedKey[Session] = TypedKey(box=id => Session(id), unbox=err => {
  match err {
    Session(id) => Some(id)
    _ => None
  }
})

///|
/// Response body writer that discards everything written to it.
priv struct DiscardWriter {}

///|
impl @io.Writer for DiscardWriter with fn write_once(_, _, offset~, len~) {
  let _ = offset
  len
}

///|
impl @moonback.Flusher for DiscardWriter with fn flush(_) {
  ()
}

///|
impl @moonback.WriteFlusher for DiscardWriter

///|
/// 会话 Cookie 的 `SameSite` 属性策略。
pub(all) enum SameSite {
  Lax
  Strict
  None
} derive(Debug, Eq)

///|
pub extend SameSite with Debug::{to_repr}

///|
pub extend SameSite with Eq::{equal, not_equal}

///|
/// create a middleware that manages sessions
/// 
/// `max_age` limits the lifetime of a session in seconds, 
/// refreshed on every save (sliding expiration).
/// Defaults to two weeks like Django.
pub fn middleware(
  session_store : &SessionStore,
  session_cookie_name~ : String = "sessionid",
  max_age~ : UInt64 = 1209600,
  same_site~ : SameSite = Lax,
  secure~ : Bool = false,
) -> @moonback.Middleware {
  let same_site_str = match same_site {
    Lax => "Lax"
    Strict => "Strict"
    None => "None"
  }
  // SameSite=None 的 cookie 按规范必须带 Secure，否则现代浏览器
  // 会直接拒收（跨站登录失效）；这里自动补上而不是报错。
  let secure_attr = if secure || same_site is None { "; Secure" } else { "" }
  let cookie_attrs = "; Path=/; HttpOnly; SameSite=\{same_site_str}\{secure_attr}"
  Middleware(next => {
    (req, res) => {
      let session_id = req.cookie().get(session_cookie_name)
      let session = if session_id is Some(id) {
        session_store
        .get(id)
        .filter(session => session.expires_at.to_uint64() > @env.now() / 1000)
      } else {
        None
      }
      let session = session.unwrap_or(Session::default())
      req.ctx.set_userdata(key, session)
      next(req, (status, headers) => {
        if status is (500..<600) || !session.modified {
          return res(status, headers)
        }
        if session.cycled || session.flushed {
          if !session.key.is_empty() {
            session_store.delete(session.key)
            session.key = ""
          }
          if session.flushed && session.data.is_empty() {
            // nothing left to persist: expire the client-side cookie
            return res(
              status,
              headers
              .to_mut()
              ..set(
                "set-cookie",
                "\{session_cookie_name}=\{cookie_attrs}; Max-Age=0",
              )
              .to_immut(),
            )
          }
        }
        session.expires_at = (@env.now() / 1000 + max_age).to_int()
        let saved = if session.key.is_empty() {
          create_session(session_store, session)
          true
        } else {
          session_store.update(session)
        }
        if saved {
          res(
            status,
            headers
            .to_mut()
            ..set(
              "set-cookie",
              "\{session_cookie_name}=\{session.key}\{cookie_attrs}",
            )
            .to_immut(),
          )
        } else {
          // the session row was deleted between load and save (e.g. a
          // concurrent logout). Django raises SessionInterrupted, which
          // maps to 400 Bad Request with an empty body.
          ignore(res(400, @moonback.Headers::default()))
          DiscardWriter::{ }
        }
      })
    }
  })
}

///|
pub fn get_session(req : @moonback.Request) -> Session? {
  req.ctx.get_userdata(key)
}
