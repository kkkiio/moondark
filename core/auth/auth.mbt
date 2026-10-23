///|
/// Errors raised by credential-binding and login operations.
/// Authentication itself never raises — it returns `None`.
pub(all) suberror AuthError {
  /// The `(kind, provider, identifier)` key is already bound to a user.
  IdentifierTaken(CredentialKind, String, String)
  /// `login`/`logout` ran without `sessions.middleware`, so there is no
  /// session to persist the auth state in.
  NoSession
  /// `login` refuses a user whose `is_active()` is `false`.
  UserInactive
  /// `update_credential` was called with no field to update.
  NothingToUpdate
} derive(Debug)

///|
pub extend AuthError with Debug::{to_repr}

///|
/// The credential-authentication service. Stateless itself — all state
/// lives in `store`; `Auth` only holds hashing configuration.
///
/// `Auth` never touches user rows: it verifies credentials and hands back
/// the opaque `user_id` they are bound to. Resolving that id into an
/// application user is the app's job (`SessionAuth::load_user`).
pub struct Auth {
  store : &CredentialStore
  bcrypt_cost : Int32
}

///|
/// `bcrypt_cost` is the bcrypt work factor (Django's default is 12).
pub fn Auth::Auth(store : &CredentialStore, bcrypt_cost~ : Int32 = 12) -> Auth {
  Auth::{ store, bcrypt_cost, }
}

///|
/// Verify `password` against the `Password` credential named `identifier`.
/// Returns the bound `user_id` on success; `None` when the identifier is
/// unknown, the password mismatches, or the credential is unusable.
///
/// `identifier` is what the user types at login — an email or username.
/// Identifiers are stored verbatim; normalize (e.g. lowercase emails)
/// before storing if the product wants case-insensitive lookup.
pub async fn Auth::authenticate_password(
  self : Self,
  identifier~ : String,
  password~ : String,
) -> String? {
  guard self.store.find_credential(Password, "", identifier) is Some(cred) else {
    return None
  }
  guard cred.secret != "" else { return None }
  let ok = @bcrypt.verify(password=@utf8.encode(password), hashed=cred.secret) catch {
    _ => false
  }
  guard ok else { return None }
  self.mark_used(cred)
  Some(cred.user_id)
}

///|
/// Resolve an OAuth identity `(provider, identifier)` — the `sub` claim
/// after the OAuth2/OIDC handshake — to the bound `user_id`.
///
/// Lookup only: on `None` the caller decides whether to create a fresh
/// user row and `bind_oauth` it, or ask the user to log in first. Never
/// auto-link by email — an unverified provider email must not take over
/// an existing local account.
pub async fn Auth::authenticate_oauth(
  self : Self,
  provider~ : String,
  identifier~ : String,
) -> String? {
  guard self.store.find_credential(OAuth, provider, identifier) is Some(cred) else {
    return None
  }
  self.mark_used(cred)
  Some(cred.user_id)
}

///|
/// Set or replace the password credential `identifier` of `user_id`:
/// registration (`user_id` comes from the application's own users-table
/// insert), a password change, or adding a password to an OAuth-only
/// account. Raises `IdentifierTaken` if the identifier belongs to a
/// different user.
pub async fn Auth::set_password(
  self : Self,
  user_id : String,
  identifier~ : String,
  password~ : String,
) -> Unit {
  let secret = hash_password(password, self.bcrypt_cost)
  match self.store.find_credential(Password, "", identifier) {
    Some(cred) if cred.user_id == user_id =>
      ignore(self.store.update_credential(Password, "", identifier, secret~))
    Some(_) => raise IdentifierTaken(Password, "", identifier)
    None => {
      let added = self.store.add_credential(CredentialModel::{
        user_id,
        kind: Password,
        provider: "",
        identifier,
        secret,
        verified: false,
        created_at: now_ms(),
        last_used_at: 0,
      })
      if !added {
        raise IdentifierTaken(Password, "", identifier)
      }
    }
  }
}

///|
/// Bind an OAuth identity to `user_id` — registration after the app
/// created its user row, or "connect your GitHub account" while logged
/// in. `identifier` is the provider's `sub` claim; `secret` may carry
/// provider tokens (e.g. a refresh token serialized as JSON) when the
/// product needs to call the provider's API later; `verified` should
/// reflect the provider's `email_verified`-style claim.
/// Raises `IdentifierTaken` if the identity already belongs to anyone.
pub async fn Auth::bind_oauth(
  self : Self,
  user_id : String,
  provider~ : String,
  identifier~ : String,
  secret~ : String = "",
  verified~ : Bool = false,
) -> Unit {
  guard self.store.add_credential(CredentialModel::{
    user_id,
    kind: OAuth,
    provider,
    identifier,
    secret,
    verified,
    created_at: now_ms(),
    last_used_at: 0,
  }) else {
    raise IdentifierTaken(OAuth, provider, identifier)
  }
}

///|
/// Stamp `last_used_at` on a successful authentication. Best-effort:
/// a failed stamp must not reject a valid login.
async fn Auth::mark_used(self : Self, cred : CredentialModel) -> Unit {
  ignore(
    self.store.update_credential(
      cred.kind,
      cred.provider,
      cred.identifier,
      last_used_at=now_ms(),
    ),
  )
}

///|
/// bcrypt-hash `password` with a fresh random salt.
fn hash_password(password : String, cost : Int32) -> String raise {
  guard @env.rand(@bcrypt.salt_length) is Some(salt) else {
    fail("platform entropy source unavailable")
  }
  @bcrypt.hash(password=@utf8.encode(password), salt~, cost~)
}

///|
fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}
