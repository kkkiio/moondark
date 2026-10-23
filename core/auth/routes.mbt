///|
/// Ready-made auth routes — the allauth `accounts/` URL set — bundled as
/// one moonback `Module`:
///
/// - `POST {url_prefix}login` — password sign-in, mounted only when `auth`
///   is given. Accepts `{"identifier", "password"}` as a JSON body or as
///   `application/x-www-form-urlencoded`, so fetch-based SPAs and plain
///   HTML form posts both work. On success the session is logged in:
///   a safe local `?next=` turns the response into a 302, otherwise it
///   is `{"id": "<user_id>"}`. Bad credentials get a uniform 401.
/// - `GET {url_prefix}{provider}/login` — per `SocialFlow` in `flows`,
///   the "sign in with {provider}" target: 302 to the provider's
///   authorization URL. The app's `Provider::redirect_uri` must point at
///   the callback below.
/// - `GET {url_prefix}{provider}/callback` — the provider's redirect
///   target; verifies `state`, resolves the identity, logs in and 302s
///   to the remembered `next` (or `/`).
/// - `POST {url_prefix}logout` — flushes the session; responds 204.
///
/// Mount after `sessions.middleware`; keep `csrf.middleware` ahead of
/// the two POST routes. The module installs no middleware of its own —
/// `SessionAuth::middleware` is still needed for `get_user`/
/// `login_required` on the app's own routes.
///
/// ```moonbit nocheck
/// ctx.use_(session_auth.routes(auth~, flows=[github]))
/// ```
///
/// Two flows sharing `Provider.name` collide on the same paths and fail
/// app initialization loudly (`RouterError`), like any duplicate route.
pub fn[U : AuthUser] SessionAuth::routes(
  self : SessionAuth[U],
  auth? : Auth,
  flows~ : Array[SocialFlow[U]] = [],
  url_prefix~ : String = "/auth/",
) -> @moonback.Module {
  let session_auth = self
  let prefix = if url_prefix.has_suffix("/") {
    url_prefix
  } else {
    "\{url_prefix}/"
  }
  @moonback.Module(ctx => {
    if auth is Some(auth) {
      ctx.post("\{prefix}login", (req, res) => {
        password_login(auth, session_auth, req, res)
      })
    }
    for flow in flows {
      let provider = flow.provider_name()
      ctx.get("\{prefix}\{provider}/login", flow.login_handler())
      ctx.get("\{prefix}\{provider}/callback", flow.callback_handler())
    }
    ctx.post("\{prefix}logout", (req, res) => {
      session_auth.logout(req) catch {
        NoSession => {
          res.send_text("sessions.middleware is not installed", status=500)
          return
        }
        err => raise err
      }
      res.send_void(status=204)
    })
  })
}

///|
/// `POST {url_prefix}login` — see `SessionAuth::routes` for the contract.
async fn[U : AuthUser] password_login(
  auth : Auth,
  session_auth : SessionAuth[U],
  req : @moonback.Request,
  res : @moonback.Responder,
) -> Unit {
  guard read_credentials(req) is Some((identifier, password)) else {
    return res.send_json(
      { "error": "identifier and password are required." },
      status=400,
    )
  }
  guard auth.authenticate_password(identifier~, password~) is Some(user_id) else {
    return res.send_json({ "error": "invalid credentials." }, status=401)
  }
  let ok = session_auth.login_by_id(req, user_id) catch {
    NoSession => {
      res.send_text("sessions.middleware is not installed", status=500)
      return
    }
    UserInactive => false
    err => raise err
  }
  guard ok else {
    return res.send_json({ "error": "account unavailable." }, status=403)
  }
  // same open-redirect guard as SocialFlow::callback_handler
  match req.query().get("next") {
    Some(next) if next.has_prefix("/") && !next.has_prefix("//") =>
      res.send_void(status=302, headers={ "location": next })
    _ => res.send_json({ "id": user_id })
  }
}

///|
/// Pull `(identifier, password)` out of a login POST body — a JSON object
/// for fetch-based SPAs, `application/x-www-form-urlencoded` for plain
/// HTML form posts.
async fn read_credentials(req : @moonback.Request) -> (String, String)? {
  if req.headers.get("content-type") is Some(ct) &&
    ct.contains("application/json") {
    match (req.body.json() catch { _ => Json::null() }) {
      Object(obj) =>
        match (obj.get("identifier"), obj.get("password")) {
          (Some(String(i)), Some(String(p))) => Some((i, p))
          _ => None
        }
      _ => None
    }
  } else {
    let form : Map[String, String] = Map([])
    for field in req.body.text().split("&") {
      guard field.split("=").collect() is [key, value] else { continue }
      form[form_decode(key)] = form_decode(value)
    }
    match (form.get("identifier"), form.get("password")) {
      (Some(i), Some(p)) => Some((i, p))
      _ => None
    }
  }
}

///|
/// `application/x-www-form-urlencoded` value decoding: `+` is a space,
/// the rest percent-encoded UTF-8. Undecodable bytes pass through
/// verbatim — a wrong credential fails at `authenticate` anyway.
fn form_decode(s : StringView) -> String {
  let replaced = s.to_owned().replace_all(old="+", new=" ")
  @utf8.decode(@percent.decode(replaced)) catch {
    _ => s.to_owned()
  }
}
