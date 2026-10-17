///|
/// SQL placeholder style used by the database backing the store.
pub(all) enum Dialect {
  /// `?` placeholders — SQLite and MySQL.
  Question
  /// `$1`, `$2`, ... placeholders — PostgreSQL.
  Dollar
}

///|
fn Dialect::placeholder(self : Dialect, n : Int32) -> String {
  match self {
    Question => "?"
    Dollar => "$\{n}"
  }
}

///|
struct DBSessionStore {
  db : @sql.DB
  table : String
  dialect : Dialect
}

///|
/// `table` is the name of the session table, see `migrate` for its schema.
/// It is interpolated into SQL statements verbatim, so it must be a trusted
/// identifier. `dialect` selects the parameter placeholder syntax; the
/// default `Question` covers SQLite and MySQL, use `Dollar` for PostgreSQL.
pub fn DBSessionStore::DBSessionStore(
  db : @sql.DB,
  table~ : String = "sessions",
  dialect~ : Dialect = Question,
) -> DBSessionStore {
  DBSessionStore::{ db, table, dialect, }
}

///|
/// Create the session table if it does not exist.
pub async fn DBSessionStore::migrate(self : Self) -> Unit {
  ignore(
    self.db.execute(
      "CREATE TABLE IF NOT EXISTS \{self.table} (session_key VARCHAR(64) PRIMARY KEY, session_data TEXT NOT NULL, expires_at BIGINT NOT NULL)",
    ),
  )
}

///|
async fn DBSessionStore::exists(self : Self, key : String) -> Bool {
  let rows = self.db.query(
    "SELECT 1 FROM \{self.table} WHERE session_key = \{self.dialect.placeholder(1)}",
    params=[key],
  )
  defer rows.close()
  rows.next() is Some(_)
}

///|
pub impl @sessions.SessionStore for DBSessionStore with fn get(self, key) {
  let rows = self.db.query(
    "SELECT session_data, expires_at FROM \{self.table} WHERE session_key = \{self.dialect.placeholder(1)}",
    params=[key],
  )
  defer rows.close()
  guard rows.next() is Some(row) else { return None }
  guard row.get("session_data") is Some(@driver.Value::String(data)) else {
    fail("sessions.db: malformed session_data")
  }
  guard row.get("expires_at") is Some(@driver.Value::Int64(expires_at)) else {
    fail("sessions.db: malformed expires_at")
  }
  guard @json.parse(data) is Object(data) else {
    fail("sessions.db: malformed session_data")
  }
  Some(
    @sessions.Session::of_model(@sessions.SessionModel::{
      key,
      data,
      expires_at: expires_at.to_int(),
    }),
  )
}

///|
pub impl @sessions.SessionStore for DBSessionStore with fn create(self, session) {
  let model = session.to_model()
  if self.exists(model.key) {
    return false
  }
  ignore(
    self.db.execute(
      "INSERT INTO \{self.table} (session_key, session_data, expires_at) VALUES (\{self.dialect.placeholder(1)}, \{self.dialect.placeholder(2)}, \{self.dialect.placeholder(3)})",
      params=[model.key, Json::object(model.data).stringify(), model.expires_at],
    ),
  )
  true
}

///|
pub impl @sessions.SessionStore for DBSessionStore with fn update(self, session) {
  let model = session.to_model()
  let result = self.db.execute(
    "UPDATE \{self.table} SET session_data = \{self.dialect.placeholder(1)}, expires_at = \{self.dialect.placeholder(2)} WHERE session_key = \{self.dialect.placeholder(3)}",
    params=[Json::object(model.data).stringify(), model.expires_at, model.key],
  )
  match result.rows_affected {
    Some(n) if n > 0 => true
    // Some(0) may mean "not found" or "unchanged data" (MySQL reports
    // changed rows); None means the driver did not report a count.
    _ => self.exists(model.key)
  }
}

///|
pub impl @sessions.SessionStore for DBSessionStore with fn delete(self, key) {
  ignore(
    self.db.execute(
      "DELETE FROM \{self.table} WHERE session_key = \{self.dialect.placeholder(1)}",
      params=[key],
    ),
  )
}

///|
pub extend DBSessionStore with @sessions.SessionStore::{
  get,
  create,
  update,
  delete,
}
