///|
/// `@moondark_sessions.SessionStore` backed by a PostgreSQL table, written in
/// PostgreSQL's native SQL (`$N` placeholders).
struct PostgresSessionStore {
  db : @sql.DB
  table : String
}

///|
/// `table` is the name of the session table, see `migrate` for its schema.
/// It is interpolated into SQL statements verbatim, so it must be a trusted
/// identifier.
pub fn PostgresSessionStore::PostgresSessionStore(
  db : @sql.DB,
  table~ : String = "sessions",
) -> PostgresSessionStore {
  PostgresSessionStore::{ db, table, }
}

///|
/// Create the session table if it does not exist.
pub async fn PostgresSessionStore::migrate(self : Self) -> Unit {
  ignore(
    self.db.execute(
      "CREATE TABLE IF NOT EXISTS \{self.table} (session_key VARCHAR(64) PRIMARY KEY, session_data TEXT NOT NULL, expires_at BIGINT NOT NULL)",
    ),
  )
}

///|
async fn PostgresSessionStore::exists(self : Self, key : String) -> Bool {
  let rows = self.db.query(
    "SELECT 1 FROM \{self.table} WHERE session_key = $1",
    params=[key],
  )
  defer rows.close()
  rows.next() is Some(_)
}

///|
pub impl @moondark_sessions.SessionStore for PostgresSessionStore with fn get(
  self,
  key,
) {
  let rows = self.db.query(
    "SELECT session_data, expires_at FROM \{self.table} WHERE session_key = $1",
    params=[key],
  )
  defer rows.close()
  guard rows.next() is Some(row) else { return None }
  guard row.get("session_data") is Some(@driver.Value::String(data)) else {
    fail("sessionstore: malformed session_data")
  }
  guard row.get("expires_at") is Some(@driver.Value::Int64(expires_at)) else {
    fail("sessionstore: malformed expires_at")
  }
  guard @json.parse(data) is Object(data) else {
    fail("sessionstore: malformed session_data")
  }
  Some(
    @moondark_sessions.Session::of_model(@moondark_sessions.SessionModel::{
      key,
      data,
      expires_at: expires_at.to_int(),
    }),
  )
}

///|
pub impl @moondark_sessions.SessionStore for PostgresSessionStore with fn create(
  self,
  session,
) {
  let model = session.to_model()
  if self.exists(model.key) {
    return false
  }
  ignore(
    self.db.execute(
      "INSERT INTO \{self.table} (session_key, session_data, expires_at) VALUES ($1, $2, $3)",
      params=[model.key, Json::object(model.data).stringify(), model.expires_at],
    ),
  )
  true
}

///|
pub impl @moondark_sessions.SessionStore for PostgresSessionStore with fn update(
  self,
  session,
) {
  let model = session.to_model()
  let result = self.db.execute(
    "UPDATE \{self.table} SET session_data = $1, expires_at = $2 WHERE session_key = $3",
    params=[Json::object(model.data).stringify(), model.expires_at, model.key],
  )
  match result.rows_affected {
    Some(n) if n > 0 => true
    _ => self.exists(model.key)
  }
}

///|
pub impl @moondark_sessions.SessionStore for PostgresSessionStore with fn delete(
  self,
  key,
) {
  ignore(
    self.db.execute("DELETE FROM \{self.table} WHERE session_key = $1", params=[
      key,
    ]),
  )
}

///|
pub extend PostgresSessionStore with @moondark_sessions.SessionStore::{
  get,
  create,
  update,
  delete,
}
