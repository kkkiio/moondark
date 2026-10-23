///|
/// The application-owned user row — distinct from the other test files'
/// fixtures because blackbox test files don't share priv items.
priv struct RoutesUser {
  id : String
  name : String
}

///|
impl @auth.AuthUser for RoutesUser with fn id(self) {
  self.id
}

///|
impl @auth.AuthUser for RoutesUser with fn is_active(_self) {
  true
}

///|
extenum @moonback.TypedBox += {
  RoutesUserBox(RoutesUser?)
}

///|
let routes_user_key : @moonback.TypedKey[RoutesUser?] = @moonback.TypedKey(
  box=u => RoutesUserBox(u),
  unbox=b => {
    match b {
      RoutesUserBox(u) => Some(u)
      _ => None
    }
  },
)

///|
/// Extract the `state` query value out of a redirect Location.
fn redirect_state(location : String) -> String {
  location.split("state=").collect()[1].split("&").collect()[0].to_owned()
}

///|
async test "auth routes: password login, logout, next handling" {
  let users : Map[String, RoutesUser] = { "u-1": { id: "u-1", name: "Alice", } }
  let auth = @auth.Auth(@auth.MemoryCredentialStore(), bcrypt_cost=4)
  auth.set_password("u-1", identifier="alice", password="p w")
  let guard_ = @auth.SessionAuth(key=routes_user_key, load_user=id => {
    users.get(id)
  })
  let session_store = @sessions.MemorySessionStore()
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(session_store))
    ctx.add_middleware(guard_.middleware())
    ctx.use_(guard_.routes(auth~))
    ctx.get(
      "/me",
      guard_.login_required((_req, res, user) => {
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
    // malformed body → 400
    let (malformed, _) = @http.post("\{base}/auth/login", "not json", headers={
      "content-type": "application/json",
    })
    assert_eq(malformed.code, 400)
    // wrong password → uniform 401, no credential-vs-user distinction
    let (denied, _) = @http.post(
      "\{base}/auth/login",
      "{\"identifier\": \"alice\", \"password\": \"nope\"}",
      headers={ "content-type": "application/json" },
    )
    assert_eq(denied.code, 401)
    // JSON login → {"id"} + session cookie
    let (login, body) = @http.post(
      "\{base}/auth/login",
      "{\"identifier\": \"alice\", \"password\": \"p w\"}",
      headers={ "content-type": "application/json" },
    )
    assert_eq(login.code, 200)
    guard body.json() is Object(obj) && obj.get("id") is Some(String("u-1")) else {
      fail("unexpected login response")
    }
    guard login.cookies is [cookie] && cookie.name == "sessionid" else {
      fail("expected session cookie")
    }
    // the session resolves the app user
    let (_, me) = @http.get("\{base}/me", headers={
      "cookie": "sessionid=\{cookie.value}",
    })
    assert_eq(me.text(), "user=u-1 Alice")
    // logout flushes the session → 204, the stale key stays anonymous
    let (logout, _) = @http.post("\{base}/auth/logout", "", headers={
      "cookie": "sessionid=\{cookie.value}",
    })
    assert_eq(logout.code, 204)
    let (anon, _) = @http.get("\{base}/me", headers={
      "cookie": "sessionid=\{cookie.value}",
    })
    assert_eq(anon.code, 302)
    // form-encoded login with a safe next → 302 (plain HTML form posts)
    let (form_login, _) = @http.post(
      "\{base}/auth/login?next=/docs",
      "identifier=alice&password=p+w",
      headers={ "content-type": "application/x-www-form-urlencoded" },
    )
    assert_eq(form_login.code, 302)
    assert_eq(form_login.headers.get("location"), Some("/docs"))
    // an unsafe next is refused — no open redirect
    let (evil, _) = @http.post(
      "\{base}/auth/login?next=//evil.test",
      "{\"identifier\": \"alice\", \"password\": \"p w\"}",
      headers={ "content-type": "application/json" },
    )
    assert_eq(evil.code, 200)
    assert_false(evil.headers.get("location") is Some(_))
    // a backslash resolves as a slash in WHATWG parsing — decoded %5C
    // must be refused too, or /\evil.example would go cross-origin
    let (backslash, _) = @http.post(
      "\{base}/auth/login?next=/%5Cevil.test",
      "{\"identifier\": \"alice\", \"password\": \"p w\"}",
      headers={ "content-type": "application/json" },
    )
    assert_eq(backslash.code, 200)
    assert_false(backslash.headers.get("location") is Some(_))
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "auth routes: oauth login/callback mounted under provider name" {
  let users : Map[String, RoutesUser] = Map([])
  let creds = @auth.MemoryCredentialStore()
  let auth = @auth.Auth(creds, bcrypt_cost=4)
  let guard_ = @auth.SessionAuth(key=routes_user_key, load_user=id => {
    users.get(id)
  })
  let sessions_ = @sessions.MemorySessionStore()
  let stub = @moonback.App(ctx => {
    ctx.post("/token", (_req, res) => {
      res.send_json({ "access_token": "at-1", "token_type": "Bearer" })
    })
    ctx.get("/userinfo", (_req, res) => {
      res.send_json({ "sub": "g-1", "name": "Alice" })
    })
  })
  defer stub.close()
  @async.with_task_group(group => {
    let stub_server = @moonback.listen(port=0)
    defer stub_server.close()
    let stub_task = group.spawn(() => stub.serve(stub_server))
    let stub_base = "http://127.0.0.1:\{stub_server.addr.port()}"
    let flow = @auth.SocialFlow(
      provider=@oauth2.Provider::{
        name: "test",
        client_id: "cid",
        client_secret: "cs",
        redirect_uri: "http://app.test/auth/test/callback",
        auth_url: "https://provider.test/authorize",
        token_url: "\{stub_base}/token",
        issuer: "",
        userinfo_url: "\{stub_base}/userinfo",
        scopes: ["openid"],
      },
      auth~,
      session_auth=guard_,
      create_user=identity => {
        let user = RoutesUser::{
          id: "u-\{identity.sub}",
          name: identity.display_name,
        }
        users[user.id] = user
        Some(user)
      },
    )
    let app = @moonback.App(ctx => {
      ctx.add_middleware(@sessions.middleware(sessions_))
      ctx.add_middleware(guard_.middleware())
      ctx.use_(guard_.routes(flows=[flow]))
      ctx.get(
        "/me",
        guard_.login_required((_req, res, user) => {
          res.send_text("user=\{user.id}")
        }),
      )
    })
    defer app.close()
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let base = "http://127.0.0.1:\{server.addr.port()}"
    // no `auth` given → the password endpoint is not mounted
    let (no_password, _) = @http.post(
      "\{base}/auth/login",
      "{\"identifier\": \"a\", \"password\": \"b\"}",
      headers={ "content-type": "application/json" },
    )
    assert_eq(no_password.code, 404)
    // GET /auth/test/login redirects to the provider
    let (login, _) = @http.get("\{base}/auth/test/login")
    assert_eq(login.code, 302)
    guard login.cookies is [cookie] && cookie.name == "sessionid" else {
      fail("expected session cookie")
    }
    let location = login.headers.get("location").unwrap()
    assert_true(location.has_prefix("https://provider.test/authorize?"))
    // the callback runs the full handshake and logs the user in
    let state = redirect_state(location)
    let (callback, _) = @http.get(
      "\{base}/auth/test/callback?code=abc&state=\{state}",
      headers={ "cookie": "sessionid=\{cookie.value}" },
    )
    assert_eq(callback.code, 302)
    guard callback.cookies is [logged_in] else {
      fail("expected rotated session cookie")
    }
    let (_, me) = @http.get("\{base}/me", headers={
      "cookie": "sessionid=\{logged_in.value}",
    })
    assert_eq(me.text(), "user=u-g-1")
    stub_task.cancel()
    stub_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}
