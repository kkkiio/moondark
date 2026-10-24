///|
/// `@moondark_sessions.SessionStore` backed by a SQLite table, written in
/// SQLite's native SQL (`?` placeholders).
struct SqliteSessionStore {
  db : @moondark_database.DB
  table : String
}

///|
/// `table` is the name of the session table, see `schema.sql` for its
/// schema. It is interpolated into SQL statements verbatim, so it must
/// be a trusted identifier.
pub fn SqliteSessionStore::SqliteSessionStore(
  db : @moondark_database.DB,
  table~ : String = "sessions",
) -> SqliteSessionStore {
  SqliteSessionStore::{ db, table, }
}

///|
async fn SqliteSessionStore::exists(self : Self, key : String) -> Bool {
  let rows = self.db.query_opt(
    "SELECT 1 FROM \{self.table} WHERE session_key = ?",
    params=[key],
  )

  rows is Some(_)
}

///|
pub impl @moondark_sessions.SessionStore for SqliteSessionStore with fn get(
  self,
  key,
) {
  let rows = self.db.query_opt(
    "SELECT session_data, expires_at FROM \{self.table} WHERE session_key = ?",
    params=[key],
  )

  guard rows is Some(row) else { return None }
  let data : String = row.get_name("session_data")
  let expires_at : Int64 = row.get_name("expires_at")
  guard @json.parse(data) is Object(data) else {
    fail("sessionstore: malformed session_data")
  }
  Some(
    @moondark_sessions.Session::of_model(@moondark_sessions.SessionModel::{
      key,
      data,
      expires_at,
    }),
  )
}

///|
pub impl @moondark_sessions.SessionStore for SqliteSessionStore with fn create(
  self,
  session,
) {
  let model = session.to_model()
  if self.exists(model.key) {
    return false
  }
  ignore(
    self.db.execute(
      "INSERT INTO \{self.table} (session_key, session_data, expires_at) VALUES (?, ?, ?)",
      params=[model.key, Json::object(model.data).stringify(), model.expires_at],
    ),
  )
  true
}

///|
pub impl @moondark_sessions.SessionStore for SqliteSessionStore with fn update(
  self,
  session,
) {
  let model = session.to_model()
  let result = self.db.execute(
    "UPDATE \{self.table} SET session_data = ?, expires_at = ? WHERE session_key = ?",
    params=[Json::object(model.data).stringify(), model.expires_at, model.key],
  )
  match result.rows_affected {
    Some(n) if n > 0 => true
    _ => self.exists(model.key)
  }
}

///|
pub impl @moondark_sessions.SessionStore for SqliteSessionStore with fn delete(
  self,
  key,
) {
  ignore(
    self.db.execute("DELETE FROM \{self.table} WHERE session_key = ?", params=[
      key,
    ]),
  )
}

///|
pub extend SqliteSessionStore with @moondark_sessions.SessionStore::{
  get,
  create,
  update,
  delete,
}
