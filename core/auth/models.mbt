///|
/// Which mechanism a credential belongs to.
pub(all) enum CredentialKind {
  /// Local password credential; `identifier` is an email or username.
  Password
  /// Third-party OAuth2/OIDC identity; `provider` names it ("google",
  /// "github", …) and `identifier` is the provider's `sub` claim.
  OAuth
  /// WebAuthn/passkey credential; `identifier` is the credential id.
  Passkey
} derive(Debug, Eq, ToJson, FromJson)

///|
pub extend CredentialKind with Debug::{to_repr}

///|
pub extend CredentialKind with Eq::{equal, not_equal}

///|
pub extend CredentialKind with ToJson::{to_json}

///|
pub extend CredentialKind with FromJson::{from_json}

///|
/// The stable string stored in the credentials table's `kind` column.
pub fn CredentialKind::name(self : Self) -> String {
  match self {
    Password => "password"
    OAuth => "oauth"
    Passkey => "passkey"
  }
}

///|
/// Inverse of `CredentialKind::name`; `None` for unknown names.
pub fn CredentialKind::of_name(name : String) -> CredentialKind? {
  match name {
    "password" => Some(Password)
    "oauth" => Some(OAuth)
    "passkey" => Some(Passkey)
    _ => None
  }
}

///|
/// One authentication method bound to a user — one row = one way to prove
/// "I am `user_id`". A user may hold several credentials of different kinds
/// (password + Google + GitHub + passkey…).
///
/// `(kind, provider, identifier)` is unique across the table: it is the
/// natural key every lookup goes through.
///
/// `user_id` is an opaque string pointing at the application's own `users`
/// table — the auth package never touches user rows.
pub(all) struct CredentialModel {
  /// the user this credential authenticates
  user_id : String
  kind : CredentialKind
  /// OAuth provider name ("google", "github", …); "" for other kinds
  provider : String
  /// the identifier within `(kind, provider)`: email/username for `Password`,
  /// the provider's `sub` claim for `OAuth`, the credential id for `Passkey`
  identifier : String
  /// credential material, interpretation depends on `kind`: bcrypt hash for
  /// `Password`, provider tokens/claims JSON for `OAuth`, public key for
  /// `Passkey`. "" marks an unusable credential (e.g. password removed).
  secret : String
  /// whether the channel behind `identifier` was verified — a confirmed
  /// email, or the provider asserting a verified email
  verified : Bool
  /// unix timestamp in ms
  created_at : Int64
  /// unix timestamp in ms of the last successful authentication; 0 = never
  last_used_at : Int64
} derive(Debug, ToJson, FromJson)

///|
pub extend CredentialModel with Debug::{to_repr}

///|
pub extend CredentialModel with ToJson::{to_json}

///|
pub extend CredentialModel with FromJson::{from_json}
