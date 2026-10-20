///|
/// OAuth2/OIDC social login — the `allauth.socialaccount` equivalent.
/// One `SocialFlow` per provider ties together the provider handshake
/// (`@oauth2`), the credential store (`Auth`) and session login
/// (`SessionAuth`), serving the two handshake handlers.
pub struct SocialFlow[U] {
  provider : @oauth2.Provider
  auth : Auth
  session_auth : SessionAuth[U]
  /// allauth's adapter hook (`is_open_for_signup`): called once for a
  /// verified Identity that has no bound credential yet — return the
  /// local user to log in (creating the user row), or `None` to refuse
  /// signup, e.g. repage's `REPAGE_ALLOWED_EMAILS` allowlist.
  create_user : async (@oauth2.Identity) -> U?
  /// send a PKCE S256 challenge with the authorization request. Off by
  /// default like allauth: confidential clients are already protected
  /// by `client_secret`; enable for extra defense in depth.
  use_pkce : Bool
}

///|
/// `create_user` is the signup-policy hook: return `None` to refuse
/// registration for the given identity.
pub fn[U] SocialFlow::SocialFlow(
  provider~ : @oauth2.Provider,
  auth~ : Auth,
  session_auth~ : SessionAuth[U],
  create_user~ : async (@oauth2.Identity) -> U?,
  use_pkce~ : Bool = false,
) -> SocialFlow[U] {
  SocialFlow::{ provider, auth, session_auth, create_user, use_pkce, }
}

///|
/// `GET {prefix}login/` — the "Sign in with {provider}" target.
/// Generates the CSRF `state`, the OIDC `nonce` and (when `use_pkce`)
/// the PKCE verifier into the session, remembers `?next=/path`, and
/// 302-redirects the browser to the provider's authorization URL.
pub fn[U] SocialFlow::login_handler(self : SocialFlow[U]) -> @moonback.Handler {
  let provider = self.provider
  let use_pkce = self.use_pkce
  (req, res) => {
    guard @sessions.get_session(req) is Some(session) else {
      res.send_text("sessions.middleware is not installed", status=500)
      return
    }
    let (state, nonce, verifier) = try {
      let verifier = if use_pkce { @oauth2.generate_token() } else { "" }
      (@oauth2.generate_token(), @oauth2.generate_token(), verifier)
    } catch {
      _ => {
        res.send_text("entropy source unavailable", status=500)
        return
      }
    }
    let next = req.query().get("next").unwrap_or("/")
    let p = provider.name
    session["_oauth_\{p}_state"] = Json(state)
    session["_oauth_\{p}_nonce"] = Json(nonce)
    session["_oauth_\{p}_next"] = Json(next)
    if verifier != "" {
      session["_oauth_\{p}_verifier"] = Json(verifier)
    }
    res.send_void(status=302, headers={
      "location": provider.authorize_url(state~, code_verifier=verifier, nonce~),
    })
  }
}

///|
/// `GET {prefix}login/callback/?code&state` — the provider's redirect
/// target. Verifies `state` against the session (one-shot), exchanges
/// `code` for the verified `Identity`, then resolves it to a local
/// user: an already-bound credential logs in at once; otherwise
/// `create_user` decides whether to register, and the new identity is
/// bound with `bind_oauth`. Finally 302 to the `next` remembered by
/// `login_handler` (or `/`), refusing `//host` open redirects.
pub fn[U : AuthUser] SocialFlow::callback_handler(
  self : SocialFlow[U],
) -> @moonback.Handler {
  let provider = self.provider
  (req, res) => {
    guard @sessions.get_session(req) is Some(session) else {
      res.send_text("sessions.middleware is not installed", status=500)
      return
    }
    let p = provider.name
    let state_key = "_oauth_\{p}_state"
    let nonce_key = "_oauth_\{p}_nonce"
    let verifier_key = "_oauth_\{p}_verifier"
    let next_key = "_oauth_\{p}_next"
    // CSRF check: the returned state must match what login stored.
    guard req.query().get("state") is Some(state) &&
      session[state_key] is Some(String(saved)) &&
      saved == state else {
      res.send_json({ "error": "OAuth state mismatch." }, status=403)
      return
    }
    guard req.query().get("code") is Some(code) else {
      res.send_json({ "error": "authorization denied." }, status=400)
      return
    }
    let nonce = match session[nonce_key] {
      Some(String(nonce)) => nonce
      _ => ""
    }
    let verifier = match session[verifier_key] {
      Some(String(verifier)) => verifier
      _ => ""
    }
    // flow state is one-shot: burn it before doing anything slow
    session[state_key] = Json("")
    session[nonce_key] = Json("")
    session[verifier_key] = Json("")
    let identity = self.provider.authenticate(
      code~,
      code_verifier=verifier,
      nonce~,
    ) catch {
      _ => {
        res.send_json({ "error": "identity verification failed." }, status=502)
        return
      }
    }
    match self.auth.authenticate_oauth(provider=p, identifier=identity.sub) {
      Some(user_id) => {
        let ok = self.session_auth.login_by_id(req, user_id) catch {
          _ => false
        }
        guard ok else {
          res.send_json({ "error": "account unavailable." }, status=403)
          return
        }
      }
      None => {
        guard (self.create_user)(identity) is Some(user) else {
          res.send_json(
            { "error": "signup is not open for this account." },
            status=403,
          )
          return
        }
        self.auth.bind_oauth(
          user.id(),
          provider=p,
          identifier=identity.sub,
          secret=identity.tokens.to_json().stringify(),
          verified=identity.email_verified,
        ) catch {
          _ => {
            res.send_json({ "error": "identity already bound." }, status=409)
            return
          }
        }
        self.session_auth.login(req, user) catch {
          _ => {
            res.send_json({ "error": "account unavailable." }, status=403)
            return
          }
        }
      }
    }
    let next = match session[next_key] {
      Some(String(next)) if next.has_prefix("/") && !next.has_prefix("//") =>
        next
      _ => "/"
    }
    session[next_key] = Json("")
    res.send_void(status=302, headers={ "location": next })
  }
}
