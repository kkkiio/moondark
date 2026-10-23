///|
/// Storage abstraction over the `credentials` table.
///
/// The store only manages authentication identities (password hashes,
/// OAuth links, …) bound to an opaque `user_id` owned by the
/// application's own `users` table.
///
/// Implementations must enforce uniqueness of `(kind, provider, identifier)`
/// on `add_credential`.
pub(open) trait CredentialStore {
  /// Insert `cred`. `false` if (kind, provider, identifier) is taken.
  async fn add_credential(Self, CredentialModel) -> Bool
  /// Find a credential by its unique key.
  async fn find_credential(
    Self,
    kind : CredentialKind,
    provider : String,
    identifier : String,
  ) -> CredentialModel?
  /// Every credential bound to `user_id`, in creation order.
  async fn credentials_of(Self, user_id : String) -> Array[CredentialModel]
  /// Update the mutable fields of the credential identified by
  /// `(kind, provider, identifier)`. Each supplied field is written;
  /// omitted ones are left untouched. `user_id` and `created_at`
  /// are immutable. Raises `NothingToUpdate` when no field is given.
  /// `false` if the credential's key is unknown.
  async fn update_credential(
    Self,
    kind : CredentialKind,
    provider : String,
    identifier : String,
    secret? : String,
    verified? : Bool,
    last_used_at? : Int64,
  ) -> Bool
  /// Remove the credential with the given key. `false` if unknown.
  async fn remove_credential(
    Self,
    kind : CredentialKind,
    provider : String,
    identifier : String,
  ) -> Bool
  /// Remove every credential bound to `user_id` — call when the
  /// application deletes its own user row.
  async fn delete_credentials_of(Self, user_id : String) -> Unit
}

///|
/// In-memory `CredentialStore`, for tests and development.
pub(all) struct MemoryCredentialStore {
  /// keyed by `cred_key`
  creds : Map[String, CredentialModel]
}

///|
pub fn MemoryCredentialStore::MemoryCredentialStore() -> MemoryCredentialStore {
  MemoryCredentialStore::{ creds: {}, }
}

///|
/// The map key for a credential's natural unique key. NUL separates the
/// components so identifiers containing ':' cannot collide.
fn cred_key(
  kind : CredentialKind,
  provider : String,
  identifier : String,
) -> String {
  "\{kind.name()}\u{0}\{provider}\u{0}\{identifier}"
}

///|
pub impl CredentialStore for MemoryCredentialStore with fn add_credential(
  self,
  cred,
) {
  let key = cred_key(cred.kind, cred.provider, cred.identifier)
  if self.creds.contains(key) {
    return false
  }
  self.creds[key] = cred
  true
}

///|
pub impl CredentialStore for MemoryCredentialStore with fn find_credential(
  self,
  kind,
  provider,
  identifier,
) {
  self.creds.get(cred_key(kind, provider, identifier))
}

///|
pub impl CredentialStore for MemoryCredentialStore with fn credentials_of(
  self,
  user_id,
) {
  self.creds.values().filter(cred => cred.user_id == user_id).collect()
}

///|
pub impl CredentialStore for MemoryCredentialStore with fn update_credential(
  self,
  kind,
  provider,
  identifier,
  secret?,
  verified?,
  last_used_at?,
) {
  guard secret is Some(_) || verified is Some(_) || last_used_at is Some(_) else {
    raise NothingToUpdate
  }
  let key = cred_key(kind, provider, identifier)
  match self.creds.get(key) {
    Some(cred) => {
      self.creds[key] = {
        ..cred,
        secret: secret.unwrap_or(cred.secret),
        verified: verified.unwrap_or(cred.verified),
        last_used_at: last_used_at.unwrap_or(cred.last_used_at),
      }
      true
    }
    None => false
  }
}

///|
pub impl CredentialStore for MemoryCredentialStore with fn remove_credential(
  self,
  kind,
  provider,
  identifier,
) {
  let key = cred_key(kind, provider, identifier)
  if self.creds.contains(key) {
    self.creds.remove(key)
    true
  } else {
    false
  }
}

///|
pub impl CredentialStore for MemoryCredentialStore with fn delete_credentials_of(
  self,
  user_id,
) {
  let stale = []
  for key, cred in self.creds {
    if cred.user_id == user_id {
      stale.push(key)
    }
  }
  for key in stale {
    self.creds.remove(key)
  }
}

///|
pub extend MemoryCredentialStore with CredentialStore::{
  add_credential,
  find_credential,
  credentials_of,
  update_credential,
  remove_credential,
  delete_credentials_of,
}
