///|
/// An unsigned JWT whose payload is `claims` — `authenticate` decodes
/// the payload without signature verification (TLS covers it), so a
/// stub endpoint can hand these out.
fn fake_id_token(claims : Json) -> String {
  fn segment(json : Json) -> String {
    let s = @base64.encode(@utf8.encode(json.stringify())[:], url_safe=true)
    let mut end = s.length()
    while end > 0 && s[end - 1] == '=' {
      end -= 1
    }
    s[:end].to_owned()
  }

  "\{segment({ "alg": "RS256", "typ": "JWT" })}.\{segment(claims)}.sig"
}

///|
test "authorize_url renders the authorization request" {
  let url = @oauth2.Provider::google(
    client_id="cid",
    client_secret="secret",
    redirect_uri="https://app.example.com/callback",
  ).authorize_url(state="state-1")
  assert_eq(
    url, "https://accounts.google.com/o/oauth2/v2/auth?response_type=code&client_id=cid&redirect_uri=https%3A%2F%2Fapp.example.com%2Fcallback&scope=openid%20email%20profile&state=state-1",
  )
  let pkce = @oauth2.Provider::google(
    client_id="cid",
    client_secret="secret",
    redirect_uri="https://app.example.com/callback",
  ).authorize_url(state="state-1", code_verifier="v", nonce="n")
  assert_true(pkce.contains("&code_challenge="))
  assert_true(pkce.contains("&code_challenge_method=S256"))
  assert_true(pkce.contains("&nonce=n"))
}

///|
test "generate_token is URL-safe and random" {
  let a = @oauth2.generate_token()
  let b = @oauth2.generate_token()
  assert_eq(a.length(), 43) // 32 bytes → 43 unpadded base64url chars
  assert_true(
    a.iter().all(c => c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '_')),
  )
  assert_true(a != b)
}

///|
/// Spin up a stub provider: `/token` answers a fixed token response,
/// `/userinfo` answers fixed claims. Returns the base URL plus the
/// serving task — the caller cancels it when done.
async fn stub_provider(
  group : @async.TaskGroup[Unit],
  token_body~ : Json,
  userinfo_body~ : Json,
) -> (String, @async.Task[Unit]) {
  let app = @moonback.App(ctx => {
    ctx.post("/token", (_req, res) => res.send_json(token_body))
    ctx.get("/userinfo", (req, res) => {
      guard req.headers.get("authorization") is Some(auth) &&
        auth == "Bearer at-1" else {
        res.send_void(status=401)
        return
      }
      res.send_json(userinfo_body)
    })
  })
  let server = @moonback.listen(port=0)
  let task = group.spawn(() => app.serve(server))
  ignore(
    group.spawn(() => {
      task.wait() catch {
        _ => ()
      }
      app.close()
      server.close()
    }),
  )
  ("http://127.0.0.1:\{server.addr.port()}", task)
}

///|
async test "authenticate verifies OIDC id_token claims" {
  let now = (@env.now() / 1000).reinterpret_as_int64()
  @async.with_task_group(group => {
    let (base, task) = stub_provider(
      group,
      token_body={
        "access_token": "at-1",
        "token_type": "Bearer",
        "expires_in": 3600,
        "id_token": fake_id_token({
          // realistic Google payload: the parser must ignore the extras
          // (azp, hd, at_hash, picture, given/family_name, locale, iat)
          // that a real Google token response carries.
          "iss": "https://issuer.test",
          "aud": "cid",
          "azp": "cid",
          "sub": "g-123",
          "hd": "example.com",
          "email": "a@x.com",
          "email_verified": true,
          "at_hash": "HK6E_P6Dh8Y93mRNtsDB1Q",
          "name": "Alice",
          "picture": "https://lh5.googleusercontent.com/photo.jpg",
          "given_name": "Alice",
          "family_name": "Doe",
          "locale": "en",
          "iat": now.to_double(),
          "exp": now.to_double() + 600.0,
          "nonce": "n-1",
        }),
      },
      userinfo_body={},
    )
    let provider = @oauth2.Provider::{
      name: "google",
      client_id: "cid",
      client_secret: "cs",
      redirect_uri: "http://app.test/cb",
      auth_url: "https://issuer.test/auth",
      token_url: "\{base}/token",
      issuer: "https://issuer.test",
      userinfo_url: "\{base}/userinfo",
      scopes: ["openid"],
    }
    let identity = provider.authenticate(code="code-1", nonce="n-1")
    assert_eq(identity.provider, "google")
    assert_eq(identity.sub, "g-123")
    assert_eq(identity.email, Some("a@x.com"))
    assert_true(identity.email_verified)
    assert_eq(identity.display_name, "Alice")
    assert_eq(identity.tokens.access_token, "at-1")
    // a wrong nonce must fail the claims check
    try provider.authenticate(code="code-1", nonce="other") catch {
      ClaimMismatch("nonce") => ()
      _ => fail("expected ClaimMismatch")
    } noraise {
      _ => fail("expected ClaimMismatch")
    }
    task.cancel()
  })
}

///|
async test "authenticate falls back to userinfo for plain OAuth providers" {
  @async.with_task_group(group => {
    let (base, task) = stub_provider(
      group,
      token_body={ "access_token": "at-1", "token_type": "Bearer" },
      userinfo_body={ "id": 42, "login": "alice", "email": "a@x.com" },
    )
    let provider = @oauth2.Provider::{
      name: "github",
      client_id: "cid",
      client_secret: "cs",
      redirect_uri: "http://app.test/cb",
      auth_url: "https://github.test/auth",
      token_url: "\{base}/token",
      issuer: "",
      userinfo_url: "\{base}/userinfo",
      scopes: [],
    }
    let identity = provider.authenticate(code="code-1")
    assert_eq(identity.sub, "42")
    assert_eq(identity.email, Some("a@x.com"))
    assert_false(identity.email_verified)
    assert_eq(identity.display_name, "alice")
    task.cancel()
  })
}

///|
async test "authenticate rejects corrupted id_token claims" {
  let now = (@env.now() / 1000).reinterpret_as_int64()
  @async.with_task_group(group => {
    // the stub swaps its id_token per scenario via this cell
    let mut id_token = ""
    let app = @moonback.App(ctx => {
      ctx.post("/token", (_req, res) => {
        res.send_json({
          "access_token": "at-1",
          "token_type": "Bearer",
          "id_token": id_token,
        })
      })
    })
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    let provider = @oauth2.Provider::{
      name: "google",
      client_id: "cid",
      client_secret: "cs",
      redirect_uri: "http://app.test/cb",
      auth_url: "https://issuer.test/auth",
      token_url: "http://127.0.0.1:\{server.addr.port()}/token",
      issuer: "https://issuer.test",
      userinfo_url: "",
      scopes: ["openid"],
    }
    guard (
        {
          "iss": "https://issuer.test",
          "aud": "cid",
          "sub": "g-123",
          "email": "a@x.com",
          "name": "Alice",
          "exp": now.to_double() + 600.0,
          "nonce": "n-1",
        } : Json)
      is Object(claims) else {
      fail("unreachable")
    }
    // corrupting iss/aud/nonce one at a time must fail the claims check
    for
      case_ in [
        ("iss", "not-the-issuer"),
        ("aud", "other-client"),
        ("nonce", "wrong"),
      ] {
      let (key, bad) = case_
      let orig = claims[key]
      claims[key] = Json(bad)
      id_token = fake_id_token(Json(claims))
      try provider.authenticate(code="c", nonce="n-1") catch {
        ClaimMismatch(_) => ()
        _ => fail("expected ClaimMismatch for \{key}")
      } noraise {
        _ => fail("expected ClaimMismatch for \{key}")
      }
      claims[key] = orig
    }
    // an expired token raises TokenExpired
    let orig = claims["exp"]
    claims["exp"] = Json(now.to_double() - 10.0)
    id_token = fake_id_token(Json(claims))
    try provider.authenticate(code="c", nonce="n-1") catch {
      TokenExpired(_, _) => ()
      _ => fail("expected TokenExpired")
    } noraise {
      _ => fail("expected TokenExpired")
    }
    claims["exp"] = orig
    // and a missing sub makes the identity unusable
    ignore(claims.remove("sub"))
    id_token = fake_id_token(Json(claims))
    try provider.authenticate(code="c", nonce="n-1") catch {
      InvalidIdToken(_) => ()
      _ => fail("expected InvalidIdToken")
    } noraise {
      _ => fail("expected InvalidIdToken")
    }
    task.cancel()
    task.wait() catch {
      _ => ()
    }
    app.close()
    server.close()
  })
}

///|
async test "authenticate rejects a token endpoint error" {
  @async.with_task_group(group => {
    let app = @moonback.App(ctx => {
      ctx.post("/token", (_req, res) => {
        res.send_json({ "error": "invalid_grant" }, status=400)
      })
    })
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    let provider = @oauth2.Provider::google(
      client_id="cid",
      client_secret="cs",
      redirect_uri="http://app.test/cb",
    )
    let provider = @oauth2.Provider::{
      ..provider,
      token_url: "http://127.0.0.1:\{server.addr.port()}/token",
    }
    try provider.authenticate(code="bad") catch {
      TokenExchangeFailed(400, _, ..) => ()
      _ => fail("expected TokenExchangeFailed")
    } noraise {
      _ => fail("expected TokenExchangeFailed")
    }
    task.cancel()
    app.close()
    server.close()
  })
}
