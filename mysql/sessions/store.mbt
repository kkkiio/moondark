///|
/// `@moondark_sessions.SessionStore` backed by a MySQL table, written in
/// MySQL's native SQL (`?` placeholders).
struct MysqlSessionStore {
  db : @sql.DB
  table : String
}

///|
/// `table` is the name of the session table, see `schema.sql` for its
/// schema. It is interpolated into SQL statements verbatim, so it must
/// be a trusted identifier.
pub fn MysqlSessionStore::MysqlSessionStore(
  db : @sql.DB,
  table~ : String = "sessions",
) -> MysqlSessionStore {
  MysqlSessionStore::{ db, table, }
}

///|
async fn MysqlSessionStore::exists(self : Self, key : String) -> Bool {
  let rows = self.db.query(
    "SELECT 1 FROM \{self.table} WHERE session_key = ?",
    params=[key],
  )
  defer rows.close()
  rows.next() is Some(_)
}

///|
pub impl @moondark_sessions.SessionStore for MysqlSessionStore with fn get(
  self,
  key,
) {
  let rows = self.db.query(
    "SELECT session_data, expires_at FROM \{self.table} WHERE session_key = ?",
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
pub impl @moondark_sessions.SessionStore for MysqlSessionStore with fn create(
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
pub impl @moondark_sessions.SessionStore for MysqlSessionStore with fn update(
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
    // MySQL reports changed rows: Some(0) may mean "not found" or
    // "unchanged data".
    _ => self.exists(model.key)
  }
}

///|
pub impl @moondark_sessions.SessionStore for MysqlSessionStore with fn delete(
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
pub extend MysqlSessionStore with @moondark_sessions.SessionStore::{
  get,
  create,
  update,
  delete,
}
