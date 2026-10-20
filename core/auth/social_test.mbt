///|
/// The application-owned user row — distinct from the middleware tests'
/// fixture because blackbox test files don't share priv items.
priv struct SocialUser {
  id : String
  name : String
  active : Bool
}

///|
impl @auth.AuthUser for SocialUser with fn id(self) {
  self.id
}

///|
impl @auth.AuthUser for SocialUser with fn is_active(self) {
  self.active
}

///|
extenum @moonback.TypedBox += {
  SocialUserBox(SocialUser?)
}

///|
let social_user_key : @moonback.TypedKey[SocialUser?] = @moonback.TypedKey(
  box=u => SocialUserBox(u),
  unbox=b => {
    match b {
      SocialUserBox(u) => Some(u)
      _ => None
    }
  },
)

///|
/// Extract the `state` query value out of a redirect Location.
fn state_of(location : String) -> String {
  location.split("state=").collect()[1].split("&").collect()[0].to_owned()
}

///|
/// Extract the session cookie value out of a Set-Cookie response.
fn session_cookie(resp : @http.Response) -> String raise {
  guard resp.cookies.iter().find_first(c => c.name == "sessionid")
    is Some(cookie) else {
    fail("expected a sessionid Set-Cookie")
  }
  cookie.value
}

///|
async test "social login: redirect, callback binds credential, user logged in" {
  let users : Map[String, SocialUser] = Map([])
  let creds = @auth.MemoryCredentialStore()
  let auth = @auth.Auth(creds, bcrypt_cost=4)
  let guard_ = @auth.SessionAuth(key=social_user_key, load_user=id => {
    users.get(id)
  })
  let sessions_ = @sessions.MemorySessionStore()
  let mut token_body = ""
  let stub = @moonback.App(ctx => {
    ctx.post("/token", (req, res) => {
      token_body = req.body.text()
      res.send_json({ "access_token": "at-1", "token_type": "Bearer" })
    })
    ctx.get("/userinfo", (_req, res) => {
      res.send_json({
        "sub": "g-1",
        "email": "alice@example.com",
        "email_verified": true,
        "name": "Alice",
      })
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
        redirect_uri: "http://app.test/accounts/test/login/callback/",
        auth_url: "https://provider.test/authorize",
        token_url: "\{stub_base}/token",
        issuer: "",
        userinfo_url: "\{stub_base}/userinfo",
        scopes: ["openid", "email"],
      },
      auth~,
      session_auth=guard_,
      create_user=identity => {
        let user = SocialUser::{
          id: "u-\{identity.sub}",
          name: identity.display_name,
          active: true,
        }
        users[user.id] = user
        Some(user)
      },
    )
    let app = @moonback.App(ctx => {
      ctx.add_middleware(@sessions.middleware(sessions_))
      ctx.add_middleware(guard_.middleware())
      ctx.get("/accounts/test/login/", flow.login_handler())
      ctx.get("/accounts/test/login/callback/", flow.callback_handler())
      ctx.get(
        "/me",
        guard_.login_required((_req, res, user) => {
          res.send_text("user=\{user.id} \{user.name}")
        }),
      )
    })
    defer app.close()
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let base = "http://127.0.0.1:\{server.addr.port()}"
    // 1. the login endpoint redirects to the provider, remembering `next`
    let (login, _) = @http.get("\{base}/accounts/test/login/?next=/docs")
    assert_eq(login.code, 302)
    let cookie_a = session_cookie(login)
    let location = login.headers.get("location").unwrap()
    assert_true(location.has_prefix("https://provider.test/authorize?"))
    assert_false(location.contains("code_challenge"))
    let state = state_of(location)
    // state and friends were parked in the session
    let stored = sessions_.get(cookie_a).unwrap()
    assert_true(stored["_oauth_test_state"] is Some(String(s)) && s == state)
    // 2. the callback exchanges the code, creates the user, binds the
    //    credential and rotates the session key on login
    let (callback, _) = @http.get(
      "\{base}/accounts/test/login/callback/?code=abc&state=\{state}",
      headers={ "cookie": "sessionid=\{cookie_a}" },
    )
    assert_eq(callback.code, 302)
    assert_eq(callback.headers.get("location").unwrap(), "/docs")
    let cookie_b = session_cookie(callback)
    assert_true(cookie_b != cookie_a)
    // the form sent to the token endpoint carried the standard fields
    assert_true(token_body.contains("grant_type=authorization_code"))
    assert_true(token_body.contains("code=abc"))
    // a credential row now links (oauth, test, g-1) → u-g-1
    guard creds.find_credential(@auth.OAuth, "test", "g-1") is Some(cred) else {
      fail("oauth credential was not bound")
    }
    assert_eq(cred.user_id, "u-g-1")
    assert_true(cred.verified)
    // 3. the rotated session resolves the new user
    let (_, body) = @http.get("\{base}/me", headers={
      "cookie": "sessionid=\{cookie_b}",
    })
    assert_eq(body.text(), "user=u-g-1 Alice")
    // 4. state is one-shot: replaying the callback fails the CSRF check
    let (replay, _) = @http.get(
      "\{base}/accounts/test/login/callback/?code=abc&state=\{state}",
      headers={ "cookie": "sessionid=\{cookie_b}" },
    )
    assert_eq(replay.code, 403)
    // 5. a second handshake resolves the bound credential without
    //    calling create_user again
    let (login2, _) = @http.get("\{base}/accounts/test/login/")
    let cookie_c = session_cookie(login2)
    let state2 = state_of(login2.headers.get("location").unwrap())
    let (callback2, _) = @http.get(
      "\{base}/accounts/test/login/callback/?code=abc&state=\{state2}",
      headers={ "cookie": "sessionid=\{cookie_c}" },
    )
    assert_eq(callback2.code, 302)
    assert_eq(users.length(), 1) // no extra user was created
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

///|
async test "social login: closed signup refuses new identities" {
  let users : Map[String, SocialUser] = Map([])
  let creds = @auth.MemoryCredentialStore()
  let auth = @auth.Auth(creds, bcrypt_cost=4)
  let guard_ = @auth.SessionAuth(key=social_user_key, load_user=id => {
    users.get(id)
  })
  let sessions_ = @sessions.MemorySessionStore()
  let stub = @moonback.App(ctx => {
    ctx.post("/token", (_req, res) => {
      res.send_json({ "access_token": "at-1", "token_type": "Bearer" })
    })
    ctx.get("/userinfo", (_req, res) => {
      res.send_json({ "sub": "outsider", "email": "o@x.com" })
    })
  })
  defer stub.close()
  @async.with_task_group(group => {
    let stub_server = @moonback.listen(port=0)
    defer stub_server.close()
    let stub_task = group.spawn(() => stub.serve(stub_server))
    let stub_base = "http://127.0.0.1:\{stub_server.addr.port()}"
    // an allowlist adapter: nobody is allowed
    let flow = @auth.SocialFlow(
      provider=@oauth2.Provider::{
        name: "test",
        client_id: "cid",
        client_secret: "cs",
        redirect_uri: "http://app.test/cb",
        auth_url: "https://provider.test/authorize",
        token_url: "\{stub_base}/token",
        issuer: "",
        userinfo_url: "\{stub_base}/userinfo",
        scopes: [],
      },
      auth~,
      session_auth=guard_,
      create_user=_ => None,
    )
    let app = @moonback.App(ctx => {
      ctx.add_middleware(@sessions.middleware(sessions_))
      ctx.add_middleware(guard_.middleware())
      ctx.get("/accounts/test/login/", flow.login_handler())
      ctx.get("/accounts/test/login/callback/", flow.callback_handler())
    })
    defer app.close()
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let base = "http://127.0.0.1:\{server.addr.port()}"
    let (login, _) = @http.get("\{base}/accounts/test/login/")
    let cookie = session_cookie(login)
    let state = state_of(login.headers.get("location").unwrap())
    let (callback, _) = @http.get(
      "\{base}/accounts/test/login/callback/?code=abc&state=\{state}",
      headers={ "cookie": "sessionid=\{cookie}" },
    )
    assert_eq(callback.code, 403)
    assert_eq(users.length(), 0)
    // a forged state never reaches the provider
    let (forged, _) = @http.get(
      "\{base}/accounts/test/login/callback/?code=abc&state=forged",
      headers={ "cookie": "sessionid=\{cookie}" },
    )
    assert_eq(forged.code, 403)
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

///|
async test "social login with PKCE sends challenge and verifier" {
  let users : Map[String, SocialUser] = Map([])
  let creds = @auth.MemoryCredentialStore()
  let auth = @auth.Auth(creds, bcrypt_cost=4)
  let guard_ = @auth.SessionAuth(key=social_user_key, load_user=id => {
    users.get(id)
  })
  let sessions_ = @sessions.MemorySessionStore()
  let mut token_body = ""
  let stub = @moonback.App(ctx => {
    ctx.post("/token", (req, res) => {
      token_body = req.body.text()
      res.send_json({ "access_token": "at-1", "token_type": "Bearer" })
    })
    ctx.get("/userinfo", (_req, res) => {
      res.send_json({ "sub": "g-1", "email": "alice@example.com" })
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
        redirect_uri: "http://app.test/accounts/test/login/callback/",
        auth_url: "https://provider.test/authorize",
        token_url: "\{stub_base}/token",
        issuer: "",
        userinfo_url: "\{stub_base}/userinfo",
        scopes: ["openid"],
      },
      auth~,
      session_auth=guard_,
      use_pkce=true,
      create_user=identity => {
        let user = SocialUser::{
          id: "u-\{identity.sub}",
          name: identity.display_name,
          active: true,
        }
        users[user.id] = user
        Some(user)
      },
    )
    let app = @moonback.App(ctx => {
      ctx.add_middleware(@sessions.middleware(sessions_))
      ctx.add_middleware(guard_.middleware())
      ctx.get("/accounts/test/login/", flow.login_handler())
      ctx.get("/accounts/test/login/callback/", flow.callback_handler())
    })
    defer app.close()
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let base = "http://127.0.0.1:\{server.addr.port()}"
    // the authorization URL carries the S256 challenge
    let (login, _) = @http.get("\{base}/accounts/test/login/")
    let cookie = session_cookie(login)
    let location = login.headers.get("location").unwrap()
    assert_true(location.contains("code_challenge="))
    assert_true(location.contains("code_challenge_method=S256"))
    // and the token exchange sends the session-stored verifier back
    let state = state_of(location)
    let (callback, _) = @http.get(
      "\{base}/accounts/test/login/callback/?code=abc&state=\{state}",
      headers={ "cookie": "sessionid=\{cookie}" },
    )
    assert_eq(callback.code, 302)
    assert_true(token_body.contains("code_verifier="))
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
