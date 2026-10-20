///|
/// The application-owned user row — arbitrary business fields allowed.
priv struct TestUser {
  id : String
  name : String
  active : Bool
}

///|
impl @auth.AuthUser for TestUser with fn id(self) {
  self.id
}

///|
impl @auth.AuthUser for TestUser with fn is_active(self) {
  self.active
}

///|
extenum @moonback.TypedBox += {
  TestUserBox(TestUser?)
}

///|
let test_user_key : @moonback.TypedKey[TestUser?] = @moonback.TypedKey(
  box=u => TestUserBox(u),
  unbox=b => {
    match b {
      TestUserBox(u) => Some(u)
      _ => None
    }
  },
)

///|
/// A `SessionAuth` backed by an in-memory "users table".
fn test_guard(users : Map[String, TestUser]) -> @auth.SessionAuth[TestUser] {
  @auth.SessionAuth(key=test_user_key, load_user=id => users.get(id))
}

///|
async test "session auth: anonymous redirect, login, protected route, logout" {
  let users : Map[String, TestUser] = {
    "u-1": { id: "u-1", name: "Alice", active: true, },
  }
  let auth_guard = test_guard(users)
  let auth = @auth.Auth(@auth.MemoryCredentialStore(), bcrypt_cost=4)
  auth.set_password("u-1", identifier="alice", password="pw")
  let session_store = @sessions.MemorySessionStore()
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(session_store))
    ctx.add_middleware(auth_guard.middleware())
    ctx.get("/touch", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      session["touched"] = Json(1)
      res.send_text("ok")
    })
    ctx.post("/login", (req, res) => {
      match auth.authenticate_password(identifier="alice", password="pw") {
        Some(id) =>
          match users.get(id) {
            Some(user) => {
              auth_guard.login(req, user) catch {
                _ => fail("login requires sessions middleware")
              }
              res.send_text("ok")
            }
            None => res.send_void(status=401)
          }
        None => res.send_void(status=401)
      }
    })
    ctx.post("/logout", (req, res) => {
      auth_guard.logout(req) catch {
        _ => fail("logout requires sessions middleware")
      }
      res.send_text("bye")
    })
    ctx.get(
      "/me",
      auth_guard.login_required((_req, res, user) => {
        res.send_text("user=\{user.id} \{user.name}")
      }),
    )
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let base = "http://127.0.0.1:\{server.addr.port()}"
    // anonymous: login_required redirects to the login page
    let (anon, _) = @http.get("\{base}/me")
    assert_eq(anon.code, 302)
    assert_eq(anon.headers.get("location"), Some("/login/?next=%2Fme"))
    // a pre-login session exists and gets a cookie
    let (touched, _) = @http.get("\{base}/touch")
    guard touched.cookies is [pre_login] else { fail("expected Set-Cookie") }
    // logging in rotates the session key (fixation protection)
    let (logged_in, _) = @http.post("\{base}/login", "", headers={
      "cookie": "sessionid=\{pre_login.value}",
    })
    assert_eq(logged_in.code, 200)
    guard logged_in.cookies is [session_cookie] else {
      fail("expected rotated Set-Cookie")
    }
    assert_true(session_cookie.value != pre_login.value)
    assert_true(session_store.get(pre_login.value) is None)
    // authenticated requests resolve the app user
    let (_, body) = @http.get("\{base}/me", headers={
      "cookie": "sessionid=\{session_cookie.value}",
    })
    assert_eq(body.text(), "user=u-1 Alice")
    // logging out flushes the session and expires the cookie
    let (bye, _) = @http.post("\{base}/logout", "", headers={
      "cookie": "sessionid=\{session_cookie.value}",
    })
    assert_eq(bye.code, 200)
    guard bye.cookies is [expired] else { fail("expected expired cookie") }
    assert_eq(expired.value, "")
    assert_true(session_store.get(session_cookie.value) is None)
    // the dead session key stays anonymous
    let (anon2, _) = @http.get("\{base}/me", headers={
      "cookie": "sessionid=\{session_cookie.value}",
    })
    assert_eq(anon2.code, 302)
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "inactive user resolves as anonymous and cannot log in" {
  let users : Map[String, TestUser] = {
    "u-1": { id: "u-1", name: "Alice", active: true, },
  }
  let auth_guard = test_guard(users)
  let session_store = @sessions.MemorySessionStore(sessions={
    "alice-session": @sessions.SessionModel::{
      key: "alice-session",
      data: { "_auth_user_id": Json("u-1") },
      expires_at: 2_000_000_000,
    },
  })
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(session_store))
    ctx.add_middleware(auth_guard.middleware())
    ctx.get("/whoami", (req, res) => {
      match auth_guard.get_user(req) {
        Some(user) => res.send_text("user=\{user.id}")
        None => res.send_text("anon")
      }
    })
    ctx.post("/login", (req, res) => {
      auth_guard.login(req, { id: "u-2", name: "Bob", active: false, }) catch {
        @auth.UserInactive => return res.send_void(status=403)
        e => raise e
      }
      res.send_text("ok")
    })
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let base = "http://127.0.0.1:\{server.addr.port()}"
    let headers : Map[@http.CaseInsensitiveString, String] = {
      "cookie": "sessionid=alice-session",
    }
    let (_, body1) = @http.get("\{base}/whoami", headers~)
    assert_eq(body1.text(), "user=u-1")
    // deactivating the row invalidates the live session on the next request
    users["u-1"] = { ..users["u-1"], active: false, }
    let (_, body2) = @http.get("\{base}/whoami", headers~)
    assert_eq(body2.text(), "anon")
    // login refuses inactive users
    let (resp, _) = @http.post("\{base}/login", "", headers~)
    assert_eq(resp.code, 403)
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "login_required without auth middleware fails loudly" {
  let users : Map[String, TestUser] = Map([])
  let auth_guard = test_guard(users)
  let app = @moonback.App(ctx => {
    ctx.get(
      "/me",
      auth_guard.login_required((_req, res, user) => {
        res.send_text("user=\{user.id}")
      }),
    )
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    // no auth_guard.middleware() installed: better a 500 than a redirect loop
    let (resp, _) = @http.get("http://127.0.0.1:\{server.addr.port()}/me")
    assert_eq(resp.code, 500)
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}
