# auth

User authentication with password credentials, OAuth2/OIDC login, and session-backed route guards.

## Quick Start

```mbt check
///|
priv struct User {
  id : String
  name : String
}

///|
impl @auth.AuthUser for User with fn id(self) {
  self.id
}

///|
impl @auth.AuthUser for User with fn is_active(_self) {
  true
}

///|
extenum @moonback.TypedBox += {
  UserBox(User?)
}

///|
let user_key : @moonback.TypedKey[User?] = @moonback.TypedKey(
  box=u => UserBox(u),
  unbox=b => {
    match b {
      UserBox(u) => Some(u)
      _ => None
    }
  },
)

///|
async test {
  let users : Map[String, User] = { "u-1": { id: "u-1", name: "Alice", } }
  let auth = @auth.Auth(@auth.MemoryCredentialStore(), bcrypt_cost=4)
  auth.set_password("u-1", identifier="alice@example.com", password="secret")

  let session_auth = @auth.SessionAuth(key=user_key, load_user=id => {
    users.get(id)
  })
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(@sessions.MemorySessionStore()))
    ctx.add_middleware(session_auth.middleware())
    ctx.post("/login", (req, res) => {
      match
        auth.authenticate_password(
          identifier="alice@example.com",
          password="secret",
        ) {
        Some(id) if session_auth.login_by_id(req, id) => res.send_text("ok")
        _ => res.send_void(status=401)
      }
    })
    ctx.get(
      "/me",
      session_auth.login_required((_req, res, user) => res.send_text(user.name)),
    )
  })
  defer app.close()

  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let base = "http://127.0.0.1:\{server.addr.port()}"

    let (login_resp, _) = @http.post("\{base}/login", "")
    guard login_resp.cookies is [cookie] else {
      fail("expected session cookie")
    }

    let (me_resp, body) = @http.get("\{base}/me", headers={
      "cookie": "sessionid=\{cookie.value}",
    })
    assert_eq(me_resp.code, 200)
    assert_eq(body.text(), "Alice")

    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}
```

## OAuth2 / OIDC

Mount `SocialFlow` handlers to add third-party login with PKCE and state verification:

```mbt nocheck
let github = @auth.SocialFlow(
  provider=@oauth2.Provider(
    name="github",
    client_id="...",
    client_secret="...",
    authorize_url="https://github.com/login/oauth/authorize",
    token_url="https://github.com/login/oauth/access_token",
    userinfo_url="https://api.github.com/user",
    redirect_uri="https://example.com/auth/github/callback",
  ),
  auth~,
  session_auth~,
  create_user=identity => Some(find_or_create_user(identity)),
)

ctx.get("/auth/github/login", github.login_handler())
ctx.get("/auth/github/callback", github.callback_handler())
```

## Ready-made routes

`SessionAuth::routes` mounts the `accounts/`-style endpoint set as one
`Module` — enough for an SPA frontend to sign users in and out:

```mbt nocheck
ctx.use_(session_auth.routes(auth~, flows=[github]))
```

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/auth/login` | `{"identifier", "password"}` (JSON or form) → `{"id"}` or 302 to `?next=` |
| `GET` | `/auth/{provider}/login` | 302 to the provider's authorization URL |
| `GET` | `/auth/{provider}/callback` | provider redirect target; 302 to remembered `next` |
| `POST` | `/auth/logout` | flush the session → 204 |

Drop `auth` for OAuth-only apps (`/auth/login` is not mounted), drop
`flows` for password-only ones, and pass `url_prefix` to move the whole
set. Mount the underlying handlers manually when a different URL layout
is needed.

## Protecting JSON APIs

Pass `login_url=None` to return JSON 401 when a request has no authenticated
session:

```mbt nocheck
ctx.get("/api/me", session_auth.login_required((_req, res, user) => {
  res.send_json({ "id": user.id() })
}, login_url=None))
```
