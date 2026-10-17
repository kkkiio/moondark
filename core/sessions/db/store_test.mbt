///|
priv struct MockDB {
  mut prepared : String
  statements : Array[(String, Array[@driver.Value])]
  mut exec_result : @driver.ExecResult
  mut query_columns : Array[String]
  mut query_rows : Array[Array[@driver.Value]]
}

///|
fn MockDB::MockDB() -> MockDB {
  MockDB::{
    prepared: "",
    statements: [],
    exec_result: { rows_affected: Some(1), last_insert_id: None, },
    query_columns: [],
    query_rows: [],
  }
}

///|
impl @driver.Connector for MockDB with fn connect(self) {
  self
}

///|
impl @driver.Conn for MockDB with fn prepare(self, query) {
  self.prepared = query
  self
}

///|
impl @driver.Conn for MockDB with fn close(self) {
  ignore(self)
}

///|
impl @driver.Conn for MockDB with fn begin(self) {
  ignore(self)
  fail("not supported")
}

///|
impl @driver.Stmt for MockDB with fn close(self) {
  ignore(self)
}

///|
impl @driver.Stmt for MockDB with fn num_input(self) {
  ignore(self)
  -1
}

///|
impl @driver.Stmt for MockDB with fn exec(self, args) {
  self.statements.push((self.prepared, args))
  self.exec_result
}

///|
impl @driver.Stmt for MockDB with fn query(self, args) {
  self.statements.push((self.prepared, args))
  MockRows::{ columns: self.query_columns, rows: self.query_rows, index: 0, }
}

///|
priv struct MockRows {
  columns : Array[String]
  rows : Array[Array[@driver.Value]]
  mut index : Int32
}

///|
impl @driver.Rows for MockRows with fn columns(self) {
  self.columns
}

///|
impl @driver.Rows for MockRows with fn next(self, dest) {
  guard self.index < self.rows.length() else { return false }
  for i, value in self.rows[self.index] {
    if i < dest.length() {
      dest[i] = value
    }
  }
  self.index += 1
  true
}

///|
impl @driver.Rows for MockRows with fn close(self) {
  ignore(self)
}

///|
fn test_session() -> @sessions.Session {
  @sessions.Session::of_model(@sessions.SessionModel::{
    key: "abc",
    data: { "a": Json::number(1) },
    expires_at: 2_000_000_000,
  })
}

///|
async test "get returns stored session" {
  let mock = MockDB()
  let store = @db.DBSessionStore::DBSessionStore(@sql.DB(mock))
  mock.query_columns = ["session_data", "expires_at"]
  mock.query_rows = [
    [@driver.Value::String("{\"a\": 1}"), @driver.Value::Int64(2_000_000_000)],
  ]
  json_inspect(store.get("abc").unwrap().to_model(), content={
    "key": "abc",
    "data": { "a": 1 },
    "expires_at": 2000000000,
  })
}

///|
async test "get returns None when missing" {
  let store = @db.DBSessionStore::DBSessionStore(@sql.DB(MockDB()))
  assert_true(store.get("abc") is None)
}

///|
async test "create inserts when key is free" {
  let mock = MockDB()
  let store = @db.DBSessionStore::DBSessionStore(@sql.DB(mock))
  assert_true(store.create(test_session()))
  debug_inspect(
    mock.statements,
    content=(
      #|[
      #|  ("SELECT 1 FROM sessions WHERE session_key = ?", [String("abc")]),
      #|  (
      #|    "INSERT INTO sessions (session_key, session_data, expires_at) VALUES (?, ?, ?)",
      #|    [String("abc"), String("{\"a\":1}"), Int64(2000000000)],
      #|  ),
      #|]
    ),
  )
}

///|
async test "create returns false when key exists" {
  let mock = MockDB()
  let store = @db.DBSessionStore::DBSessionStore(@sql.DB(mock))
  mock.query_columns = ["1"]
  mock.query_rows = [[@driver.Value::Int64(1)]]
  assert_false(store.create(test_session()))
}

///|
async test "update returns true on affected row" {
  let store = @db.DBSessionStore::DBSessionStore(@sql.DB(MockDB()))
  assert_true(store.update(test_session()))
}

///|
async test "update falls back to existence check" {
  // e.g. MySQL reports 0 when the data did not change
  let mock = MockDB()
  let store = @db.DBSessionStore::DBSessionStore(@sql.DB(mock))
  mock.exec_result = { rows_affected: Some(0), last_insert_id: None, }
  mock.query_columns = ["1"]
  mock.query_rows = [[@driver.Value::Int64(1)]]
  assert_true(store.update(test_session()))
}

///|
async test "update returns false when row is missing" {
  let mock = MockDB()
  let store = @db.DBSessionStore::DBSessionStore(@sql.DB(mock))
  mock.exec_result = { rows_affected: Some(0), last_insert_id: None, }
  assert_false(store.update(test_session()))
}

///|
async test "delete issues DELETE" {
  let mock = MockDB()
  let store = @db.DBSessionStore::DBSessionStore(@sql.DB(mock))
  store.delete("abc")
  assert_true(mock.statements[0].0.contains("DELETE FROM sessions"))
}
