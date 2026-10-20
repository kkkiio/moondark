///|
/// The contract an application user type must satisfy to authenticate via
/// `SessionAuth`.
///
/// `id` is the primary key serialized into the session — `String` covers
/// integer (`id.to_string()`), UUID and composite keys alike. `is_active`
/// gates authentication: return `false` to reject logins and invalidate
/// existing sessions on the very next request.
pub(open) trait AuthUser {
  fn id(Self) -> String
  fn is_active(Self) -> Bool
}

///|
/// The session key storing the authenticated `user_id`.
let session_key : String = "_auth_user_id"

///|
/// Session-cookie authentication for an application-defined user type `U`.
///
/// `SessionAuth` brings its own user row: `load_user` resolves the
/// session-stored id into the app's full user model in one query, and
/// `key` is the request-userdata slot the resolved user is stored under.
/// One `SessionAuth` instance serves `middleware`/`login`/`logout`/
/// `get_user`/`login_required` for the whole app.
///
/// ```moonbit nocheck
/// struct AppUser {
///   id : String
///   name : String
///   is_admin : Bool
/// }
///
/// impl @auth.AuthUser for AppUser with fn id(self) {
///   self.id
/// }
///
/// impl @auth.AuthUser for AppUser with fn is_active(self) {
///   self.id != "banned"
/// }
///
/// extenum @moonback.TypedBox += {
///   AppUserBox(AppUser?)
/// }
///
/// let user_key : @moonback.TypedKey[AppUser?] = TypedKey(box=u => AppUserBox(u), unbox=b => {
///   match b {
///     AppUserBox(u) => Some(u)
///     _ => None
///   }
/// })
///
/// let auth = @auth.SessionAuth(key=user_key, load_user=id => db.find_user(id))
/// ```
pub struct SessionAuth[U] {
  /// userdata slot for the resolved user; always stores `U?`
  key : @moonback.TypedKey[U?]
  /// resolves a session-stored user id into the application's user model
  load_user : async (String) -> U?
}

///|
/// `key` is the request-userdata slot the resolved user is stored under —
/// the app owns one `extenum @moonback.TypedBox` variant for it.
/// `load_user` resolves a session-stored user id into the app's own user
/// model; it is also the account-policy hook (return `None` for banned
/// or deleted users to invalidate their sessions).
pub fn[U] SessionAuth::SessionAuth(
  key~ : @moonback.TypedKey[U?],
  load_user~ : async (String) -> U?,
) -> SessionAuth[U] {
  SessionAuth::{ key, load_user, }
}

///|
/// Resolve the request's authenticated user once and store the conclusion
/// in userdata — every request gets `Some(user)` or `None`, so downstream
/// `get_user`/`login_required` never hit the store again. Install *after*
/// `sessions.middleware`; requests without a session resolve to `None`.
pub fn[U : AuthUser] SessionAuth::middleware(
  self : SessionAuth[U],
) -> @moonback.Middleware {
  let key = self.key
  let load_user = self.load_user
  @moonback.Middleware(next => {
    (req, res) => {
      let user = match @sessions.get_session(req) {
        Some(session) =>
          match session[session_key] {
            Some(String(id)) => load_user(id).filter(user => user.is_active())
            _ => None
          }
        None => None
      }
      req.ctx.set_userdata(key, user)
      next(req, res)
    }
  })
}

///|
/// `request.user`: the user resolved by `middleware` — `None` when the
/// request is anonymous, when `middleware` is not installed, or after
/// `logout` cleared the state mid-request.
pub fn[U] SessionAuth::get_user(
  self : SessionAuth[U],
  req : @moonback.Request,
) -> U? {
  req.ctx.get_userdata(self.key).bind(u => u)
}

///|
/// Log `user` in: rotate the session key (fixation protection; a *different*
/// authenticated user flushes the session first), store `user.id()`, and
/// update request-local auth state so `get_user` sees the user at once.
///
/// Raises `UserInactive` when `user.is_active()` is `false`, `NoSession`
/// without `sessions.middleware` (or outside the request lifecycle).
pub fn[U : AuthUser] SessionAuth::login(
  self : SessionAuth[U],
  req : @moonback.Request,
  user : U,
) -> Unit raise AuthError {
  guard user.is_active() else { raise UserInactive }
  match @sessions.get_session(req) {
    Some(session) => {
      match session[session_key] {
        Some(String(existing)) if existing != user.id() => session.flush()
        _ => session.cycle_key()
      }
      session[session_key] = Json(user.id())
      req.ctx.set_userdata(self.key, Some(user))
    }
    None => raise NoSession
  }
}

///|
/// Log the current user out: flush the session (data gone, row deleted,
/// expired cookie) and mark this request anonymous.
/// Raises `NoSession` without `sessions.middleware`.
pub fn[U] SessionAuth::logout(
  self : SessionAuth[U],
  req : @moonback.Request,
) -> Unit raise AuthError {
  match @sessions.get_session(req) {
    Some(session) => {
      session.flush()
      req.ctx.set_userdata(self.key, None)
    }
    None => raise NoSession
  }
}

///|
/// Log in by a stored `user_id`: resolve it through `load_user` and
/// delegate to `login`. Returns `false` when the id no longer resolves
/// to an active user (deleted or deactivated row) — the caller decides
/// how to report that. Raises `NoSession`/`UserInactive` plus whatever
/// `load_user` itself may raise.
pub async fn[U : AuthUser] SessionAuth::login_by_id(
  self : SessionAuth[U],
  req : @moonback.Request,
  user_id : String,
) -> Bool {
  match (self.load_user)(user_id) {
    Some(user) => {
      self.login(req, user)
      true
    }
    None => false
  }
}

///|
/// The `login_required` decorator: anonymous requests get a 302 to
/// `login_url?next=<current path>`; authenticated ones run `handler` with
/// the resolved user as a third argument. A request that never saw
/// `middleware` gets a loud 500 — silent redirect loops are worse.
pub fn[U] SessionAuth::login_required(
  self : SessionAuth[U],
  handler : async (@moonback.Request, @moonback.Responder, U) -> Unit,
  login_url~ : String = "/login/",
) -> @moonback.Handler {
  let key = self.key
  (req, res) => {
    match req.ctx.get_userdata(key) {
      Some(Some(user)) => handler(req, res, user)
      Some(None) => {
        let next = match req.search {
          Some(search) => "\{req.path}?\{search}"
          None => "\{req.path}"
        }
        res.send_void(status=302, headers={
          "location": "\{login_url}?next=\{@percent.encode(next)}",
        })
      }
      None =>
        res.send_text("SessionAuth::middleware is not installed", status=500)
    }
  }
}
