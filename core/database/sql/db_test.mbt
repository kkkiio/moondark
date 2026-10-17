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
  mut commit_count : Int32
  mut rollback_count : Int32
}

///|
/// Connector creating a fresh `MockConn` on every `connect`, recording
/// per-connection state so tests can observe pool health validation.
/// `fail_exec` is copied into every new connection so tests can also
/// make the fresh connections used by retries fail.
priv struct MockConnector {
  stats : MockStats
  conns : Array[MockConn]
  mut fail_exec : Error?
}

///|
fn MockConnector::MockConnector() -> MockConnector {
  {
    stats: {
      connect_count: 0,
      close_count: 0,
      commit_count: 0,
      rollback_count: 0,
    },
    conns: [],
    fail_exec: None,
  }
}

///|
impl @driver.Connector for MockConnector with fn connect(self) {
  let conn = MockConn::{
    stats: self.stats,
    closed: false,
    valid: true,
    fail_reset: false,
    fail_ping: false,
    fail_exec: self.fail_exec,
    fail_begin: None,
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
  mut fail_exec : Error?
  mut fail_begin : Error?
  mut reset_count : Int32
  mut ping_count : Int32
}

///|
impl @driver.Conn for MockConn with fn prepare(self, _query) {
  MockStmt::{ conn: self, executed: [], }
}

///|
impl @driver.Conn for MockConn with fn close(self) {
  self.closed = true
  self.stats.close_count += 1
}

///|
impl @driver.Conn for MockConn with fn begin(self) {
  if self.fail_begin is Some(e) {
    raise e
  }
  MockTx::{ stats: self.stats, }
}

///|
/// Statement returned by `MockConn::prepare`; `exec` records its
/// arguments and fails with the error in `conn.fail_exec`, if any.
priv struct MockStmt {
  conn : MockConn
  executed : Array[Array[@driver.Value]]
}

///|
impl @driver.Stmt for MockStmt with fn close(self) {
  ignore(self)
}

///|
impl @driver.Stmt for MockStmt with fn num_input(self) {
  ignore(self)
  -1
}

///|
impl @driver.Stmt for MockStmt with fn exec(self, args) {
  if self.conn.fail_exec is Some(e) {
    raise e
  }
  self.executed.push(args)
  @driver.ExecResult::{ rows_affected: Some(1), last_insert_id: None, }
}

///|
impl @driver.Stmt for MockStmt with fn query(_self, _args) {
  MockAnswerDBRows::{ index: 0, }
}

///|
/// Transaction returned by `MockConn::begin`, counting commits and
/// rollbacks in the shared stats.
priv struct MockTx {
  stats : MockStats
}

///|
impl @driver.Tx for MockTx with fn commit(self) {
  self.stats.commit_count += 1
}

///|
impl @driver.Tx for MockTx with fn rollback(self) {
  self.stats.rollback_count += 1
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
async test "ping raising BadConn discards the connection and retries" {
  let connector = MockConnector()
  let db = @sql.DB(connector)
  defer db.close()
  db.ping()
  connector.conns[0].fail_ping = true
  // the stale connection is discarded and the ping retried on a fresh one
  db.ping()
  assert_true(connector.conns[0].closed)
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
  // the ping fails on the stale connection and is transparently retried
  // on the replacement opened during release
  db.ping()
  assert_eq(connector.stats.connect_count, 2)
  assert_eq(connector.conns[1].ping_count, 1)
  db.ping()
  assert_eq(connector.stats.connect_count, 2)
  assert_eq(connector.conns[1].ping_count, 2)
}

///|
async test "execute is retried on a fresh connection after BadConn" {
  let connector = MockConnector()
  let db = @sql.DB(connector)
  defer db.close()
  db.ping()
  connector.conns[0].fail_exec = Some(@driver.BadConn(Failure("exec failed")))
  let result = db.execute("INSERT INTO t VALUES (1)")
  assert_eq(result.rows_affected, Some(1))
  assert_eq(connector.stats.connect_count, 2)
  assert_true(connector.conns[0].closed)
}

///|
async test "execute gives up after too many BadConn failures" {
  let connector = MockConnector()
  connector.fail_exec = Some(@driver.BadConn(Failure("exec failed")))
  let db = @sql.DB(connector)
  defer db.close()
  try db.execute("INSERT INTO t VALUES (1)") catch {
    e => assert_true(e is @driver.BadConn(_))
  } noraise {
    _ => fail("expected execute to raise BadConn")
  }
  // 3 attempts (1 initial + 2 retries), each on a fresh connection;
  // every discarded connection is eagerly replaced, so a 4th connection
  // was opened and sits idle in the pool
  assert_eq(connector.stats.close_count, 3)
  assert_eq(connector.stats.connect_count, 4)
  assert_true(connector.conns[0].closed)
  assert_true(connector.conns[1].closed)
  assert_true(connector.conns[2].closed)
}

///|
async test "execute does not retry errors other than BadConn" {
  let connector = MockConnector()
  let db = @sql.DB(connector)
  defer db.close()
  db.ping()
  connector.conns[0].fail_exec = Some(Failure("syntax error"))
  try db.execute("INSERT INTO t VALUES (1)") catch {
    e => assert_true(e is Failure(_))
  } noraise {
    _ => fail("expected execute to fail")
  }
  // no retry happened and the connection returned to the pool
  assert_eq(connector.stats.connect_count, 1)
  assert_true(!connector.conns[0].closed)
}

///|
async test "with_transaction retries when begin raises BadConn" {
  let connector = MockConnector()
  let db = @sql.DB(connector)
  defer db.close()
  db.ping()
  connector.conns[0].fail_begin = Some(@driver.BadConn(Failure("begin failed")))
  let result = db.with_transaction(tx => {
    ignore(tx.execute("INSERT INTO t VALUES (1)"))
    42
  })
  assert_eq(result, 42)
  assert_eq(connector.stats.commit_count, 1)
  assert_eq(connector.stats.connect_count, 2)
  assert_true(connector.conns[0].closed)
}

///|
async test "with_transaction rolls back and does not retry when f fails" {
  let connector = MockConnector()
  let db = @sql.DB(connector)
  defer db.close()
  let f : async (@sql.Transaction) -> Unit = tx => {
    ignore(tx.execute("INSERT INTO t VALUES (1)"))
    fail("boom")
  }
  try db.with_transaction(f) catch {
    e => assert_true(e is Failure(_))
  } noraise {
    _ => fail("expected with_transaction to fail")
  }
  assert_eq(connector.stats.rollback_count, 1)
  assert_eq(connector.stats.commit_count, 0)
  assert_eq(connector.stats.connect_count, 1)
}

///|
async test "connection past max_lifetime is discarded on acquire" {
  let connector = MockConnector()
  // A nanosecond-scale lifetime effectively means "expires after ~0ms":
  // the next acquire observes the connection as expired.
  let db = @sql.DB(connector, max_lifetime=@time.Duration::of(nanoseconds=1))
  defer db.close()
  db.ping()
  @async.sleep(15)
  db.ping()
  assert_true(connector.conns[0].closed)
  assert_eq(connector.stats.connect_count, 2)
  assert_eq(connector.conns[1].ping_count, 1)
}

///|
async test "connection idle longer than max_idle_time is discarded" {
  let connector = MockConnector()
  let db = @sql.DB(connector, max_idle_time=@time.Duration::of(nanoseconds=1))
  defer db.close()
  db.ping()
  // Reused without sleeping, the connection is not discarded: sleeping
  // is what advances idle time past the ~0ms threshold.
  db.ping()
  assert_eq(connector.stats.connect_count, 1)
  assert_eq(connector.conns[0].ping_count, 2)
  @async.sleep(15)
  db.ping()
  assert_true(connector.conns[0].closed)
  assert_eq(connector.stats.connect_count, 2)
  assert_eq(connector.conns[1].ping_count, 1)
}

///|
async test "connection past max_lifetime is eagerly replaced on release" {
  let connector = MockConnector()
  let db = @sql.DB(connector, max_lifetime=@time.Duration::of(nanoseconds=1))
  defer db.close()
  // Keep the connection checked out past its lifetime, then return it:
  // `release` closes it and opens a replacement right away.
  let rows = db.query("SELECT 1")
  @async.sleep(15)
  rows.close()
  assert_true(connector.conns[0].closed)
  // connect_count grew during `release`, before the next operation
  assert_eq(connector.stats.connect_count, 2)
  db.ping()
  assert_eq(connector.conns[1].ping_count, 1)
}
