///|
async test "first write creates session and sets cookie" {
  let store = @sessions.MemorySessionStore()
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(store))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session["user"] = Json("alice")
      res.send_text("ok")
    })
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let (resp, _body) = @http.get("http://127.0.0.1:\{server.addr.port()}/")
    assert_eq(resp.code, 200)
    guard resp.cookies is [cookie] else { fail("expected one Set-Cookie") }
    assert_eq(cookie.name, "sessionid")
    // 32 chars from [a-z0-9], server-generated
    assert_eq(cookie.value.length(), 32)
    assert_true(cookie.value.iter().all(c => c is ('a'..<='z' | '0'..<='9')))
    guard store.get(cookie.value) is Some(saved) else {
      fail("session was not persisted")
    }
    assert_true(saved["user"] is Some(String("alice")))
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "session data persists across requests" {
  let store = @sessions.MemorySessionStore()
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(store))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      let count = match session["count"] {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
      session["count"] = Json(count + 1)
      res.send_text("count=\{count + 1}")
    })
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let url = "http://127.0.0.1:\{server.addr.port()}/"
    let (resp1, body1) = @http.get(url)
    assert_eq(body1.text(), "count=1")
    guard resp1.cookies is [cookie1] else { fail("expected Set-Cookie") }
    // second request reuses the session and refreshes the same key
    let (resp2, body2) = @http.get(url, headers={
      "cookie": "sessionid=\{cookie1.value}",
    })
    assert_eq(body2.text(), "count=2")
    guard resp2.cookies is [cookie2] else {
      fail("expected refreshed Set-Cookie")
    }
    assert_eq(cookie2.value, cookie1.value)
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "unmodified session does not save or set cookie" {
  let store = @sessions.MemorySessionStore()
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(store))
    ctx.get("/", (_req, res) => res.send_text("ok"))
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let (resp, _body) = @http.get("http://127.0.0.1:\{server.addr.port()}/")
    assert_eq(resp.code, 200)
    assert_true(resp.cookies.is_empty())
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "read-only access does not save or set cookie" {
  let store = @sessions.MemorySessionStore(sessions={
    "existing-session-key": @sessions.SessionModel::{
      key: "existing-session-key",
      data: { "user": Json("bob") },
      expires_at: 2_000_000_000,
    },
  })
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(store))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      let user = match session["user"] {
        Some(String(name)) => name
        _ => "anon"
      }
      res.send_text("user=\{user}")
    })
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let (resp, body) = @http.get("http://127.0.0.1:\{server.addr.port()}/", headers={
      "cookie": "sessionid=existing-session-key",
    })
    // the stored session was loaded
    assert_eq(body.text(), "user=bob")
    // but not modified, so nothing is saved and no cookie is sent
    assert_true(resp.cookies.is_empty())
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "client-supplied key that misses the store is not adopted" {
  let store = @sessions.MemorySessionStore()
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(store))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session["x"] = Json(1)
      res.send_text("ok")
    })
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let (resp, _body) = @http.get("http://127.0.0.1:\{server.addr.port()}/", headers={
      "cookie": "sessionid=attacker-controlled-key",
    })
    guard resp.cookies is [cookie] else { fail("expected Set-Cookie") }
    // the server must generate its own key, not adopt the client's
    assert_true(cookie.value != "attacker-controlled-key")
    assert_eq(cookie.value.length(), 32)
    assert_true(store.get("attacker-controlled-key") is None)
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "expired session is replaced by a new key" {
  let store = @sessions.MemorySessionStore(sessions={
    "old-session-key": @sessions.SessionModel::{
      key: "old-session-key",
      data: { "user": Json("bob") },
      // expired in 1970
      expires_at: 1,
    },
  })
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(store))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session["x"] = Json(1)
      res.send_text("ok")
    })
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let (resp, _body) = @http.get("http://127.0.0.1:\{server.addr.port()}/", headers={
      "cookie": "sessionid=old-session-key",
    })
    guard resp.cookies is [cookie] else { fail("expected Set-Cookie") }
    assert_true(cookie.value != "old-session-key")
    assert_eq(cookie.value.length(), 32)
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "5xx response skips session save" {
  let store = @sessions.MemorySessionStore()
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(store))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session["x"] = Json(1)
      res.send_void(status=500)
    })
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let (resp, _body) = @http.get("http://127.0.0.1:\{server.addr.port()}/")
    assert_eq(resp.code, 500)
    assert_true(resp.cookies.is_empty())
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
/// A store that can never create a session, forcing `create_session`
/// to exhaust its retry budget.
priv struct ConflictStore {}

///|
impl @sessions.SessionStore for ConflictStore with fn get(_, _) {
  None
}

///|
impl @sessions.SessionStore for ConflictStore with fn create(_, _) {
  false
}

///|
impl @sessions.SessionStore for ConflictStore with fn update(_, _) {
  false
}

///|
impl @sessions.SessionStore for ConflictStore with fn delete(_, _) {
  ()
}

///|
async test "session deleted mid-request responds 400" {
  let store = @sessions.MemorySessionStore(sessions={
    "doomed-session-key": @sessions.SessionModel::{
      key: "doomed-session-key",
      data: {},
      expires_at: 2_000_000_000,
    },
  })
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(store))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session["x"] = Json(1)
      // simulate a concurrent logout deleting the row between
      // the load at request start and the save at response time
      store.delete("doomed-session-key")
      res.send_text("ok")
    })
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let (resp, body) = @http.get("http://127.0.0.1:\{server.addr.port()}/", headers={
      "cookie": "sessionid=doomed-session-key",
    })
    // Django: UpdateError -> SessionInterrupted -> 400 Bad Request
    debug_inspect(
      (resp.code, body.text()),
      content=(
        #|(400, "")
      ),
    )
    assert_true(resp.cookies.is_empty())
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "session creation gives up after repeated key collisions" {
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(ConflictStore::{ }))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session["x"] = Json(1)
      res.send_text("ok")
    })
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let (resp, _body) = @http.get("http://127.0.0.1:\{server.addr.port()}/")
    // Django would retry forever; we bound it and surface a 500
    debug_inspect(
      resp.code,
      content=(
        #|500
      ),
    )
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "cycle_key rotates the key and keeps the data" {
  let store = @sessions.MemorySessionStore(sessions={
    "old-key": @sessions.SessionModel::{
      key: "old-key",
      data: { "user": Json("bob") },
      expires_at: 2_000_000_000,
    },
  })
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(store))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session.cycle_key()
      res.send_text("ok")
    })
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let (resp, _) = @http.get("http://127.0.0.1:\{server.addr.port()}/", headers={
      "cookie": "sessionid=old-key",
    })
    guard resp.cookies is [cookie] else { fail("expected rotated Set-Cookie") }
    assert_true(cookie.value != "old-key")
    assert_eq(cookie.value.length(), 32)
    // the row moved to the new key with its data intact
    assert_true(store.get("old-key") is None)
    guard store.get(cookie.value) is Some(moved) else {
      fail("session was not re-keyed")
    }
    assert_true(moved["user"] is Some(String("bob")))
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "flush deletes the session and expires the cookie" {
  let store = @sessions.MemorySessionStore(sessions={
    "doomed": @sessions.SessionModel::{
      key: "doomed",
      data: { "user": Json("bob") },
      expires_at: 2_000_000_000,
    },
  })
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(store))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session.flush()
      res.send_text("ok")
    })
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let (resp, _) = @http.get("http://127.0.0.1:\{server.addr.port()}/", headers={
      "cookie": "sessionid=doomed",
    })
    guard resp.cookies is [cookie] else { fail("expected expired Set-Cookie") }
    assert_eq(cookie.value, "")
    assert_true(store.get("doomed") is None)
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "flush then write starts a fresh session" {
  let store = @sessions.MemorySessionStore(sessions={
    "old-key": @sessions.SessionModel::{
      key: "old-key",
      data: { "user": Json("bob") },
      expires_at: 2_000_000_000,
    },
  })
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(store))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session.flush()
      session["user2"] = Json("carol")
      res.send_text("ok")
    })
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let (resp, _) = @http.get("http://127.0.0.1:\{server.addr.port()}/", headers={
      "cookie": "sessionid=old-key",
    })
    guard resp.cookies is [cookie] else { fail("expected fresh Set-Cookie") }
    assert_true(cookie.value != "old-key")
    assert_true(store.get("old-key") is None)
    guard store.get(cookie.value) is Some(fresh) else {
      fail("fresh session was not persisted")
    }
    // only post-flush data survived; the flushed data is gone
    assert_true(fresh["user"] is None)
    assert_true(fresh["user2"] is Some(String("carol")))
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "session cookie security attributes default SameSite=Lax and custom Strict Secure" {
  let default_store = @sessions.MemorySessionStore()
  let last_default_set_cookie : Ref[String?] = { val: None, }
  let default_app = @moonback.App(ctx => {
    ctx.add_middleware(
      @moonback.Middleware(next => {
        (req, res) => {
          next(req, (status, headers) => {
            last_default_set_cookie.val = headers
              .get("set-cookie")
              .map(v => v.to_owned())
            res(status, headers)
          })
        }
      }),
    )
    ctx.add_middleware(@sessions.middleware(default_store))
    ctx.get("/login", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session["user"] = Json("alice")
      res.send_text("ok")
    })
    ctx.get("/logout", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session.flush()
      res.send_text("ok")
    })
  })
  defer default_app.close()

  let strict_store = @sessions.MemorySessionStore()
  let last_strict_set_cookie : Ref[String?] = { val: None, }
  let strict_app = @moonback.App(ctx => {
    ctx.add_middleware(
      @moonback.Middleware(next => {
        (req, res) => {
          next(req, (status, headers) => {
            last_strict_set_cookie.val = headers
              .get("set-cookie")
              .map(v => v.to_owned())
            res(status, headers)
          })
        }
      }),
    )
    ctx.add_middleware(
      @sessions.middleware(
        strict_store,
        same_site=@sessions.Strict,
        secure=true,
      ),
    )
    ctx.get("/login", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session["user"] = Json("alice")
      res.send_text("ok")
    })
    ctx.get("/logout", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session.flush()
      res.send_text("ok")
    })
  })
  defer strict_app.close()

  @async.with_task_group(group => {
    let s1 = @moonback.listen(port=0)
    defer s1.close()
    let t1 = group.spawn(() => default_app.serve(s1))
    let base1 = "http://127.0.0.1:\{s1.addr.port()}"
    let (resp1, _) = @http.get("\{base1}/login")
    guard resp1.cookies is [c1] else { fail("expected Set-Cookie") }
    assert_eq(c1.path, Some("/"))
    assert_eq(c1.http_only, true)
    assert_eq(c1.secure, false)
    assert_eq(c1.extensions, ["SameSite=Lax"])
    assert_eq(
      last_default_set_cookie.val,
      Some("sessionid=\{c1.value}; Path=/; HttpOnly; SameSite=Lax"),
    )
    let (resp1_out, _) = @http.get("\{base1}/logout", headers={
      "cookie": "sessionid=\{c1.value}",
    })
    guard resp1_out.cookies is [c1_out] else { fail("expected Set-Cookie") }
    assert_eq(c1_out.max_age, Some(0L))
    assert_eq(c1_out.extensions, ["SameSite=Lax"])
    assert_eq(
      last_default_set_cookie.val,
      Some("sessionid=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"),
    )
    t1.cancel()
    t1.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }

    let s2 = @moonback.listen(port=0)
    defer s2.close()
    let t2 = group.spawn(() => strict_app.serve(s2))
    let base2 = "http://127.0.0.1:\{s2.addr.port()}"
    let (resp2, _) = @http.get("\{base2}/login")
    guard resp2.cookies is [c2] else { fail("expected Set-Cookie") }
    assert_eq(c2.path, Some("/"))
    assert_eq(c2.http_only, true)
    assert_eq(c2.secure, true)
    assert_eq(c2.extensions, ["SameSite=Strict"])
    assert_eq(
      last_strict_set_cookie.val,
      Some("sessionid=\{c2.value}; Path=/; HttpOnly; SameSite=Strict; Secure"),
    )
    let (resp2_out, _) = @http.get("\{base2}/logout", headers={
      "cookie": "sessionid=\{c2.value}",
    })
    guard resp2_out.cookies is [c2_out] else { fail("expected Set-Cookie") }
    assert_eq(c2_out.secure, true)
    assert_eq(c2_out.max_age, Some(0L))
    assert_eq(c2_out.extensions, ["SameSite=Strict"])
    assert_eq(
      last_strict_set_cookie.val,
      Some("sessionid=; Path=/; HttpOnly; SameSite=Strict; Secure; Max-Age=0"),
    )
    t2.cancel()
    t2.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}
