# sessions

Cookie-backed HTTP session middleware with pluggable storage backends.

## Quick Start

```mbt nocheck
///|
async test {
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(@sessions.MemorySessionStore()))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      let count = match session["count"] {
        Some(Number(n, ..)) => n.to_int() + 1
        _ => 1
      }
      session["count"] = Json(count)
      res.send_text("Counter: \{count}")
    })
  })
  defer app.close()

  let server = @moonback.listen(port=3000)
  app.serve(server)
}
```

By default, the session cookie persists across browser restarts for the same
`max_age` as the server session (two weeks, in milliseconds). Every successful
save renews both lifetimes; read-only requests do not renew either. Cookie
`Max-Age` uses whole seconds rounded down, with zero or negative lifetimes
expiring the cookie immediately.

To use a browser-session cookie instead, set `expire_at_browser_close=true`:

```mbt check
///|
test {
  let store = @sessions.MemorySessionStore()
  let _ = @sessions.middleware(store, expire_at_browser_close=true)
}
```

This omits cookie expiration attributes; the server session still expires after
`max_age`. Browsers with session restoration may restore browser-session cookies.
Call `session.flush()` on logout to delete the stored session and expire the
cookie in either mode. As with other session changes, 5xx responses skip saving.

Existing applications now get persistent cookies on their next session save.
Set `expire_at_browser_close=true` to retain the previous cookie behavior.
