///|
/// `@moondark_auth.CredentialStore` backed by a SQLite table, written in
/// SQLite's native SQL (`?` placeholders).
struct SqliteCredentialStore {
  db : @sql.DB
  table : String
}

///|
/// `table` is the name of the credentials table, see `schema.sql` for
/// its schema. It is interpolated into SQL statements verbatim, so it
/// must be a trusted identifier.
pub fn SqliteCredentialStore::SqliteCredentialStore(
  db : @sql.DB,
  table~ : String = "credentials",
) -> SqliteCredentialStore {
  SqliteCredentialStore::{ db, table, }
}

///|
/// Decode one row of `credential_columns` into a `CredentialModel`.
fn row_to_credential(row : @sql.Row) -> @moondark_auth.CredentialModel raise {
  guard row.get("user_id") is Some(@driver.Value::String(user_id)) else {
    fail("credentialstore: malformed user_id")
  }
  guard row.get("kind") is Some(@driver.Value::String(kind)) else {
    fail("credentialstore: malformed kind")
  }
  guard @moondark_auth.CredentialKind::of_name(kind) is Some(kind) else {
    fail("credentialstore: unknown kind \{kind}")
  }
  guard row.get("provider") is Some(@driver.Value::String(provider)) else {
    fail("credentialstore: malformed provider")
  }
  guard row.get("identifier") is Some(@driver.Value::String(identifier)) else {
    fail("credentialstore: malformed identifier")
  }
  guard row.get("secret") is Some(@driver.Value::String(secret)) else {
    fail("credentialstore: malformed secret")
  }
  guard row.get("verified") is Some(@driver.Value::Int64(verified)) else {
    fail("credentialstore: malformed verified")
  }
  guard row.get("created_at") is Some(@driver.Value::Int64(created_at)) else {
    fail("credentialstore: malformed created_at")
  }
  let last_used_at = match row.get("last_used_at") {
    Some(@driver.Value::Int64(ts)) => Some(ts)
    _ => None
  }
  @moondark_auth.CredentialModel::{
    user_id,
    kind,
    provider,
    identifier,
    secret,
    verified: verified != 0,
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
pub impl @moondark_auth.CredentialStore for SqliteCredentialStore with fn add_credential(
  self,
  cred,
) {
  let result = self.db.execute(
    "INSERT OR IGNORE INTO \{self.table} (\{CREDENTIAL_COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    params=[
      cred.user_id,
      cred.kind.name(),
      cred.provider,
      cred.identifier,
      cred.secret,
      if cred.verified {
        1
      } else {
        0
      },
      cred.created_at,
      match cred.last_used_at {
        Some(ts) => @driver.Value::Int64(ts)
        None => @driver.Value::Null
      },
    ],
  )
  match result.rows_affected {
    Some(n) => n > 0
    None =>
      self.find_credential(cred.kind, cred.provider, cred.identifier) is Some(_)
  }
}

///|
pub impl @moondark_auth.CredentialStore for SqliteCredentialStore with fn find_credential(
  self,
  kind,
  provider,
  identifier,
) {
  let rows = self.db.query(
    "SELECT \{CREDENTIAL_COLUMNS} FROM \{self.table} WHERE kind = ? AND provider = ? AND identifier = ?",
    params=[kind.name(), provider, identifier],
  )
  defer rows.close()
  guard rows.next() is Some(row) else { return None }
  Some(row_to_credential(row))
}

///|
pub impl @moondark_auth.CredentialStore for SqliteCredentialStore with fn credentials_of(
  self,
  user_id,
) {
  let rows = self.db.query(
    "SELECT \{CREDENTIAL_COLUMNS} FROM \{self.table} WHERE user_id = ? ORDER BY created_at, rowid",
    params=[user_id],
  )
  defer rows.close()
  let creds = []
  while rows.next() is Some(row) {
    creds.push(row_to_credential(row))
  }
  creds
}

///|
pub impl @moondark_auth.CredentialStore for SqliteCredentialStore with fn update_credential(
  self,
  cred,
) {
  let result = self.db.execute(
    "UPDATE \{self.table} SET secret = ?, verified = ?, last_used_at = ? WHERE kind = ? AND provider = ? AND identifier = ?",
    params=[
      cred.secret,
      if cred.verified {
        1
      } else {
        0
      },
      match cred.last_used_at {
        Some(ts) => @driver.Value::Int64(ts)
        None => @driver.Value::Null
      },
      cred.kind.name(),
      cred.provider,
      cred.identifier,
    ],
  )
  match result.rows_affected {
    Some(n) if n > 0 => true
    _ =>
      // Unchanged data still counts as an update.
      self.find_credential(cred.kind, cred.provider, cred.identifier) is Some(_)
  }
}

///|
pub impl @moondark_auth.CredentialStore for SqliteCredentialStore with fn remove_credential(
  self,
  kind,
  provider,
  identifier,
) {
  if self.find_credential(kind, provider, identifier) is None {
    return false
  }
  ignore(
    self.db.execute(
      "DELETE FROM \{self.table} WHERE kind = ? AND provider = ? AND identifier = ?",
      params=[kind.name(), provider, identifier],
    ),
  )
  true
}

///|
pub impl @moondark_auth.CredentialStore for SqliteCredentialStore with fn delete_credentials_of(
  self,
  user_id,
) {
  ignore(
    self.db.execute("DELETE FROM \{self.table} WHERE user_id = ?", params=[
      user_id,
    ]),
  )
}

///|
pub extend SqliteCredentialStore with @moondark_auth.CredentialStore::{
  add_credential,
  find_credential,
  credentials_of,
  update_credential,
  remove_credential,
  delete_credentials_of,
}
