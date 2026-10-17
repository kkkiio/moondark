///|
priv struct MockAnswerDB {
  mut last_prepared : String
  executed : Array[Array[@driver.Value]]
}

///|
fn MockAnswerDB::MockAnswerDB() -> MockAnswerDB {
  { last_prepared: "", executed: [], }
}

///|
impl @driver.Connector for MockAnswerDB with fn connect(self) {
  self
}

///|
impl @driver.Conn for MockAnswerDB with fn prepare(self, query) {
  self.last_prepared = query
  self
}

///|
impl @driver.Conn for MockAnswerDB with fn close(self) {
  ignore(self)
}

///|
impl @driver.Conn for MockAnswerDB with fn begin(self) {
  ignore(self)
  fail("not supported")
}

///|
impl @driver.Stmt for MockAnswerDB with fn close(self) {
  ignore(self)
}

///|
impl @driver.Stmt for MockAnswerDB with fn num_input(self) {
  ignore(self)
  -1
}

///|
impl @driver.Stmt for MockAnswerDB with fn exec(self, args) {
  self.executed.push(args)
  @driver.ExecResult::{ rows_affected: Some(1), last_insert_id: None, }
}

///|
impl @driver.Stmt for MockAnswerDB with fn query(self, args) {
  ignore(self)
  ignore(args)
  MockAnswerDBRows::{ index: 0, }
}

///|
priv struct MockAnswerDBRows {
  mut index : Int32
}

///|
impl @driver.Rows for MockAnswerDBRows with fn columns(self) {
  ignore(self)
  ["question", "answer"]
}

///|
impl @driver.Rows for MockAnswerDBRows with fn next(self, dest) {
  guard self.index < 1 else { return false }
  dest[0] = @driver.Value::String(
    "Answer to the Ultimate Question of Life, the Universe, and Everything",
  )
  dest[1] = @driver.Value::String("42")
  self.index += 1
  true
}

///|
impl @driver.Rows for MockAnswerDBRows with fn close(self) {
  ignore(self)
}

///|
priv struct MockStats {
  mut connect_count : Int32
  mut close_count : Int32
}

///|
/// Connector creating a fresh `MockConn` on every `connect`, recording
/// per-connection state so tests can observe pool health validation.
priv struct MockConnector {
  stats : MockStats
  conns : Array[MockConn]
}

///|
fn MockConnector::MockConnector() -> MockConnector {
  { stats: { connect_count: 0, close_count: 0, }, conns: [], }
}

///|
impl @driver.Connector for MockConnector with fn connect(self) {
  let conn = MockConn::{
    stats: self.stats,
    closed: false,
    valid: true,
    fail_reset: false,
    fail_ping: false,
    reset_count: 0,
    ping_count: 0,
  }
  self.stats.connect_count += 1
  self.conns.push(conn)
  conn
}

///|
priv struct MockConn {
  stats : MockStats
  mut closed : Bool
  mut valid : Bool
  mut fail_reset : Bool
  mut fail_ping : Bool
  mut reset_count : Int32
  mut ping_count : Int32
}

///|
impl @driver.Conn for MockConn with fn prepare(self, _query) {
  ignore(self)
  fail("not supported")
}

///|
impl @driver.Conn for MockConn with fn close(self) {
  self.closed = true
  self.stats.close_count += 1
}

///|
impl @driver.Conn for MockConn with fn begin(self) {
  ignore(self)
  fail("not supported")
}

///|
impl @driver.Conn for MockConn with fn is_valid(self) {
  self.valid
}

///|
impl @driver.Conn for MockConn with fn ping(self) {
  if self.fail_ping {
    raise @driver.BadConn(Failure("ping failed"))
  }
  self.ping_count += 1
}

///|
impl @driver.Conn for MockConn with fn reset_session(self) {
  self.reset_count += 1
  if self.fail_reset {
    raise @driver.BadConn(Failure("session expired"))
  }
}

///|
async test "ping" {
  let db = @sql.DB(MockAnswerDB())
  defer db.close()
  db.ping()
}

///|
async test "reset_session is called when reusing a returned connection" {
  let connector = MockConnector()
  let db = @sql.DB(connector)
  defer db.close()
  db.ping()
  db.ping()
  assert_eq(connector.stats.connect_count, 1)
  assert_eq(connector.conns[0].reset_count, 1)
  assert_eq(connector.conns[0].ping_count, 2)
}

///|
async test "idle connection failing is_valid is discarded" {
  let connector = MockConnector()
  let db = @sql.DB(connector)
  defer db.close()
  db.ping()
  connector.conns[0].valid = false
  db.ping()
  assert_eq(connector.stats.connect_count, 2)
  assert_eq(connector.stats.close_count, 1)
  assert_true(connector.conns[0].closed)
  assert_eq(connector.conns[1].ping_count, 1)
}

///|
async test "returned connection failing reset_session is discarded" {
  let connector = MockConnector()
  let db = @sql.DB(connector)
  defer db.close()
  db.ping()
  connector.conns[0].fail_reset = true
  db.ping()
  assert_eq(connector.stats.connect_count, 2)
  assert_eq(connector.conns[0].reset_count, 1)
  assert_true(connector.conns[0].closed)
  assert_eq(connector.conns[1].ping_count, 1)
}

///|
async test "ping raising BadConn discards the connection" {
  let connector = MockConnector()
  let db = @sql.DB(connector)
  defer db.close()
  db.ping()
  connector.conns[0].fail_ping = true
  try db.ping() catch {
    e => assert_true(e is @driver.BadConn(_))
  } noraise {
    _ => fail("expected ping to raise BadConn")
  }
  assert_true(connector.conns[0].closed)
  db.ping()
  assert_eq(connector.stats.connect_count, 2)
  assert_eq(connector.conns[1].ping_count, 1)
}

///|
async test "discarded bad connection is eagerly replaced" {
  let connector = MockConnector()
  let db = @sql.DB(connector, max_idle=1, max_open=1)
  defer db.close()
  db.ping()
  connector.conns[0].fail_ping = true
  try db.ping() catch {
    e => assert_true(e is @driver.BadConn(_))
  } noraise {
    _ => fail("expected ping to raise BadConn")
  }
  // the replacement is opened during release, not on the next operation
  assert_eq(connector.stats.connect_count, 2)
  db.ping()
  assert_eq(connector.stats.connect_count, 2)
  assert_eq(connector.conns[1].ping_count, 1)
}
