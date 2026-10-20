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
/// create a middleware that manages sessions
/// 
/// `max_age` limits the lifetime of a session in seconds, 
/// refreshed on every save (sliding expiration).
/// Defaults to two weeks like Django.
pub fn middleware(
  session_store : &SessionStore,
  session_cookie_name~ : String = "sessionid",
  max_age~ : UInt64 = 1209600,
) -> @moonback.Middleware {
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
                "\{session_cookie_name}=; Path=/; HttpOnly; Max-Age=0",
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
              "\{session_cookie_name}=\{session.key}; Path=/; HttpOnly",
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
