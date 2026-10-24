///|
/// `@moondark_auth.CredentialStore` backed by a PostgreSQL table, written
/// in PostgreSQL's native SQL (`$N` placeholders).
struct PostgresCredentialStore {
  db : @moondark_database.DB
  table : String
}

///|
/// `table` is the name of the credentials table, see `schema.sql` for
/// its schema. It is interpolated into SQL statements verbatim, so it
/// must be a trusted identifier.
pub fn PostgresCredentialStore::PostgresCredentialStore(
  db : @moondark_database.DB,
  table~ : String = "credentials",
) -> PostgresCredentialStore {
  PostgresCredentialStore::{ db, table, }
}

///|
/// Decode one row of `CREDENTIAL_COLUMNS` into a `CredentialModel`.
fn row_to_credential(
  row : @moondark_database.Row,
) -> @moondark_auth.CredentialModel raise {
  let user_id : String = row.get_name("user_id")
  let kind : String = row.get_name("kind")
  guard @moondark_auth.CredentialKind::of_name(kind) is Some(kind) else {
    fail("credentialstore: unknown kind \{kind}")
  }
  let provider : String = row.get_name("provider")
  let identifier : String = row.get_name("identifier")
  let secret : String = row.get_name("secret")
  let verified : Bool = row.get_name("verified")
  let created_at : Int64 = row.get_name("created_at")
  let last_used_at : Int64 = row.get_name("last_used_at")
  @moondark_auth.CredentialModel::{
    user_id,
    kind,
    provider,
    identifier,
    secret,
    verified,
    created_at,
    last_used_at,
  }
}

///|
/// The columns every `SELECT` in this package reads, in one place so
/// `row_to_credential` never goes stale.
const CREDENTIAL_COLUMNS =
  #|user_id, kind, provider, identifier, secret, verified, created_at, last_used_at

///|
pub impl @moondark_auth.CredentialStore for PostgresCredentialStore with fn add_credential(
  self,
  cred,
) {
  let result = self.db.execute(
    "INSERT INTO \{self.table} (\{CREDENTIAL_COLUMNS}) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (kind, provider, identifier) DO NOTHING",
    params=[
      cred.user_id,
      cred.kind.name(),
      cred.provider,
      cred.identifier,
      cred.secret,
      cred.verified,
      cred.created_at,
      cred.last_used_at,
    ],
  )
  match result.rows_affected {
    Some(n) => n > 0
    None =>
      self.find_credential(cred.kind, cred.provider, cred.identifier) is Some(_)
  }
}

///|
pub impl @moondark_auth.CredentialStore for PostgresCredentialStore with fn find_credential(
  self,
  kind,
  provider,
  identifier,
) {
  let rows = self.db.query_opt(
    "SELECT \{CREDENTIAL_COLUMNS} FROM \{self.table} WHERE kind = $1 AND provider = $2 AND identifier = $3",
    params=[kind.name(), provider, identifier],
  )

  guard rows is Some(row) else { return None }
  Some(row_to_credential(row))
}

///|
pub impl @moondark_auth.CredentialStore for PostgresCredentialStore with fn credentials_of(
  self,
  user_id,
) {
  // creation order: created_at first, natural key as a deterministic
  // tie-break for credentials minted in the same millisecond.
  let rows = self.db.query_all(
    "SELECT \{CREDENTIAL_COLUMNS} FROM \{self.table} WHERE user_id = $1 ORDER BY created_at, kind, provider, identifier",
    params=[user_id],
  )

  let creds = []
  for row in rows {
    creds.push(row_to_credential(row))
  }
  creds
}

///|
pub impl @moondark_auth.CredentialStore for PostgresCredentialStore with fn update_credential(
  self,
  kind,
  provider,
  identifier,
  secret?,
  verified?,
  last_used_at?,
) {
  guard secret is Some(_) || verified is Some(_) || last_used_at is Some(_) else {
    raise @moondark_auth.NothingToUpdate
  }
  let result = self.db.execute(
    "UPDATE \{self.table} SET secret = COALESCE($1, secret), verified = COALESCE($2, verified), last_used_at = COALESCE($3, last_used_at) WHERE kind = $4 AND provider = $5 AND identifier = $6",
    params=[secret, verified, last_used_at, kind.name(), provider, identifier],
  )
  match result.rows_affected {
    Some(n) if n > 0 => true
    _ =>
      // Unchanged data still counts as an update.
      self.find_credential(kind, provider, identifier) is Some(_)
  }
}

///|
/// `DELETE ... RETURNING` reports whether a row was actually deleted in
/// one statement — no pre-check roundtrip, no count ambiguity.
pub impl @moondark_auth.CredentialStore for PostgresCredentialStore with fn remove_credential(
  self,
  kind,
  provider,
  identifier,
) {
  let rows = self.db.query_opt(
    "DELETE FROM \{self.table} WHERE kind = $1 AND provider = $2 AND identifier = $3 RETURNING user_id",
    params=[kind.name(), provider, identifier],
  )

  rows is Some(_)
}

///|
pub impl @moondark_auth.CredentialStore for PostgresCredentialStore with fn delete_credentials_of(
  self,
  user_id,
) {
  ignore(
    self.db.execute("DELETE FROM \{self.table} WHERE user_id = $1", params=[
      user_id,
    ]),
  )
}

///|
pub extend PostgresCredentialStore with @moondark_auth.CredentialStore::{
  add_credential,
  find_credential,
  credentials_of,
  update_credential,
  remove_credential,
  delete_credentials_of,
}
