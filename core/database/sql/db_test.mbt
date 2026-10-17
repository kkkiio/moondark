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
  ((self : &@driver.Conn), @driver.NoopExecutor::{ })
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
    prepare_count: 0,
  }
  self.stats.connect_count += 1
  self.conns.push(conn)
  (conn, @driver.NoopExecutor::{ })
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
  mut prepare_count : Int32
}

///|
impl @driver.Conn for MockConn with fn prepare(self, _query) {
  self.prepare_count += 1
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
/// Spawn `pair`'s executor on a fresh task group, wait for the pool's
/// workers to be ready, run `f` with the `DB`, then close the pool.
async fn run_db(
  pair : (@sql.DB, @sql.DBExecutor),
  f : async (@sql.DB) -> Unit,
) -> Unit {
  let (db, executor) = pair
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    f(db)
  })
}

///|
async test "ping" {
  run_db(@sql.DB::new(MockAnswerDB()), db => db.ping())
}

///|
async test "reset_session is called when reusing a returned connection" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    db.ping()
    db.ping()
    assert_eq(connector.stats.connect_count, 1)
    assert_eq(connector.conns[0].reset_count, 1)
    assert_eq(connector.conns[0].ping_count, 2)
  })
}

///|
async test "idle connection failing is_valid is discarded" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    db.ping()
    connector.conns[0].valid = false
    db.ping()
    // the invalid connection was retired through the close worker
    @async.sleep(15)
    assert_eq(connector.stats.connect_count, 2)
    assert_eq(connector.stats.close_count, 1)
    assert_true(connector.conns[0].closed)
    assert_eq(connector.conns[1].ping_count, 1)
  })
}

///|
async test "returned connection failing reset_session is discarded" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    db.ping()
    connector.conns[0].fail_reset = true
    db.ping()
    @async.sleep(15)
    assert_eq(connector.stats.connect_count, 2)
    assert_eq(connector.conns[0].reset_count, 1)
    assert_true(connector.conns[0].closed)
    assert_eq(connector.conns[1].ping_count, 1)
  })
}

///|
async test "ping raising BadConn discards the connection and retries" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    db.ping()
    connector.conns[0].fail_ping = true
    // the stale connection is discarded and the ping retried on a fresh one
    db.ping()
    @async.sleep(15)
    assert_true(connector.conns[0].closed)
    assert_eq(connector.stats.connect_count, 2)
    assert_eq(connector.conns[1].ping_count, 1)
  })
}

///|
async test "discarded bad connection frees capacity for a fresh one" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector, max_idle=1, max_open=1), db => {
    db.ping()
    connector.conns[0].fail_ping = true
    // the ping fails on the stale connection and is transparently
    // retried on a fresh one opened once `serve_closes` frees the slot
    db.ping()
    assert_eq(connector.stats.connect_count, 2)
    assert_eq(connector.conns[1].ping_count, 1)
    db.ping()
    assert_eq(connector.stats.connect_count, 2)
    assert_eq(connector.conns[1].ping_count, 2)
  })
}

///|
async test "execute is retried on a fresh connection after BadConn" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    db.ping()
    connector.conns[0].fail_exec = Some(@driver.BadConn(Failure("exec failed")))
    let result = db.execute("INSERT INTO t VALUES (1)")
    assert_eq(result.rows_affected, Some(1))
    assert_eq(connector.stats.connect_count, 2)
    @async.sleep(15)
    assert_true(connector.conns[0].closed)
  })
}

///|
async test "execute gives up after too many BadConn failures" {
  let connector = MockConnector()
  connector.fail_exec = Some(@driver.BadConn(Failure("exec failed")))
  run_db(@sql.DB::new(connector), db => {
    try db.execute("INSERT INTO t VALUES (1)") catch {
      e => assert_true(e is @driver.BadConn(_))
    } noraise {
      _ => fail("expected execute to raise BadConn")
    }
    // 3 attempts (1 initial + 2 retries), each on a fresh connection
    @async.sleep(15)
    assert_eq(connector.stats.close_count, 3)
    assert_eq(connector.stats.connect_count, 3)
    assert_true(connector.conns[0].closed)
    assert_true(connector.conns[1].closed)
    assert_true(connector.conns[2].closed)
  })
}

///|
async test "execute does not retry errors other than BadConn" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
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
  })
}

///|
async test "with_transaction retries when begin raises BadConn" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    db.ping()
    connector.conns[0].fail_begin = Some(
      @driver.BadConn(Failure("begin failed")),
    )
    let result = db.with_transaction(tx => {
      ignore(tx.execute("INSERT INTO t VALUES (1)"))
      42
    })
    assert_eq(result, 42)
    assert_eq(connector.stats.commit_count, 1)
    assert_eq(connector.stats.connect_count, 2)
    @async.sleep(15)
    assert_true(connector.conns[0].closed)
  })
}

///|
async test "with_transaction rolls back and does not retry when f fails" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
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
  })
}

///|
async test "connection past max_lifetime is discarded on acquire" {
  let connector = MockConnector()
  // A nanosecond-scale lifetime effectively means "expires after ~0ms":
  // the next acquire observes the connection as expired.
  run_db(
    @sql.DB::new(connector, max_lifetime=@time.Duration::of(nanoseconds=1)),
    db => {
      db.ping()
      @async.sleep(15)
      db.ping()
      @async.sleep(15)
      assert_true(connector.conns[0].closed)
      assert_eq(connector.stats.connect_count, 2)
      assert_eq(connector.conns[1].ping_count, 1)
    },
  )
}

///|
async test "connection idle longer than max_idle_time is discarded" {
  let connector = MockConnector()
  run_db(
    @sql.DB::new(connector, max_idle_time=@time.Duration::of(nanoseconds=1)),
    db => {
      db.ping()
      // Reused without sleeping, the connection is not discarded: sleeping
      // is what advances idle time past the ~0ms threshold.
      db.ping()
      assert_eq(connector.stats.connect_count, 1)
      assert_eq(connector.conns[0].ping_count, 2)
      @async.sleep(15)
      db.ping()
      @async.sleep(15)
      assert_true(connector.conns[0].closed)
      assert_eq(connector.stats.connect_count, 2)
      assert_eq(connector.conns[1].ping_count, 1)
    },
  )
}

///|
async test "connection past max_lifetime is retired on release" {
  let connector = MockConnector()
  run_db(
    @sql.DB::new(connector, max_lifetime=@time.Duration::of(nanoseconds=1)),
    db => {
      // Keep the connection checked out past its lifetime, then return
      // it: `release` retires it through the close worker, and the next
      // operation lazily opens a replacement.
      let rows = db.query("SELECT 1")
      @async.sleep(15)
      rows.close()
      @async.sleep(15)
      assert_true(connector.conns[0].closed)
      // no connection is created before the next operation needs one
      assert_eq(connector.stats.connect_count, 1)
      db.ping()
      assert_eq(connector.stats.connect_count, 2)
      assert_eq(connector.conns[1].ping_count, 1)
    },
  )
}

///|
async test "stats reports open, in_use and idle connections" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    db.ping()
    let stats = db.stats()
    assert_eq(stats.max_open, 10)
    assert_eq(stats.open, 1)
    assert_eq(stats.in_use, 0)
    assert_eq(stats.idle, 1)
    assert_eq(stats.wait_count, 0)
    assert_eq(stats.wait_duration_ms, 0)
  })
}

///|
async test "stats counts a checked out connection as in_use" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    db.with_transaction(tx => {
      ignore(tx.execute("INSERT INTO t VALUES (1)"))
      let stats = db.stats()
      assert_eq(stats.in_use, 1)
      assert_eq(stats.idle, 0)
      assert_eq(stats.open, 1)
    })
    let stats = db.stats()
    assert_eq(stats.in_use, 0)
    assert_eq(stats.idle, 1)
  })
}

///|
async test "stats counts connections closed for exceeding max_lifetime" {
  let connector = MockConnector()
  run_db(
    @sql.DB::new(connector, max_lifetime=@time.Duration::of(nanoseconds=1)),
    db => {
      db.ping()
      @async.sleep(15)
      // the expired connection is discarded on the next acquire
      db.ping()
      assert_eq(db.stats().max_lifetime_closed, 1)
    },
  )
}

///|
async test "stats counts connections closed for exceeding max_idle_time" {
  let connector = MockConnector()
  run_db(
    @sql.DB::new(connector, max_idle_time=@time.Duration::of(nanoseconds=1)),
    db => {
      db.ping()
      @async.sleep(15)
      // the connection idle past max_idle_time is discarded on acquire
      db.ping()
      assert_eq(db.stats().max_idle_time_closed, 1)
      assert_eq(db.stats().max_lifetime_closed, 0)
    },
  )
}

///|
async test "stats counts connections closed when the idle queue is full" {
  let connector = MockConnector()
  // max_idle=0 means no connection may sit idle, so every release
  // overflows the idle queue and closes the connection.
  run_db(@sql.DB::new(connector, max_idle=0), db => {
    db.ping()
    let stats = db.stats()
    assert_eq(stats.max_idle_closed, 1)
    assert_eq(stats.open, 0)
    assert_eq(stats.in_use, 0)
    assert_eq(stats.idle, 0)
  })
}

///|
async test "stats counts acquisitions that had to wait for a connection" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector, max_idle=0, max_open=1), db => {
    // Hold the single connection checked out so the spawned ping blocks
    // in `acquire` until `rows.close()` frees its slot.
    let rows = db.query("SELECT 1")
    @async.with_task_group(group => {
      group.spawn_bg(allow_failure=true, () => db.ping())
      @async.sleep(15)
      rows.close()
    })
    let stats = db.stats()
    assert_eq(stats.wait_count, 1)
    assert_true(stats.wait_duration_ms > 0)
  })
}

///|
async test "conn checks out a dedicated connection" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    let conn = db.conn()
    assert_eq(db.stats().in_use, 1)
    conn.ping()
    assert_eq(connector.conns[0].ping_count, 1)
    conn.close()
    assert_eq(db.stats().in_use, 0)
    // the returned connection is reused by the next operation
    db.ping()
    assert_eq(connector.stats.connect_count, 1)
    assert_eq(connector.conns[0].ping_count, 2)
  })
}

///|
async test "conn query holds the connection until conn.close" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    let conn = db.conn()
    let rows = conn.query("SELECT 1")
    // closing the rows does not return the dedicated connection
    rows.close()
    assert_eq(db.stats().in_use, 1)
    conn.ping()
    assert_eq(connector.conns[0].ping_count, 1)
    conn.close()
    assert_eq(db.stats().in_use, 0)
  })
}

///|
async test "conn operations raise after close" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    let conn = db.conn()
    conn.close()
    // closing again is a no-op
    conn.close()
    try conn.ping() catch {
      _ => ()
    } noraise {
      _ => fail("expected ping on a closed conn to raise")
    }
  })
}

///|
async test "prepared statement is cached per connection" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    let stmt = db.prepare("UPDATE answers SET answer = ?")
    ignore(stmt.execute())
    // the pool reuses the same connection, so the cached statement is
    // reused without preparing again
    ignore(stmt.execute())
    assert_eq(connector.stats.connect_count, 1)
    assert_eq(connector.conns[0].prepare_count, 1)
    stmt.close()
  })
}

///|
async test "least recently used cached statement is evicted" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector, max_stmts_per_conn=1), db => {
    let stmt1 = db.prepare("UPDATE a SET x = 1")
    let stmt2 = db.prepare("UPDATE b SET x = 1")
    ignore(stmt1.execute())
    ignore(stmt2.execute())
    // the second prepare evicted the first statement
    assert_eq(connector.conns[0].prepare_count, 2)
    // re-executing the evicted statement prepares it again
    ignore(stmt1.execute())
    assert_eq(connector.conns[0].prepare_count, 3)
    stmt1.close()
    stmt2.close()
  })
}

///|
async test "statement bound to a conn fails after the conn is closed" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    let conn = db.conn()
    let stmt = conn.prepare("UPDATE answers SET answer = ?")
    ignore(stmt.execute())
    assert_eq(connector.conns[0].prepare_count, 1)
    conn.close()
    try stmt.execute() catch {
      _ => ()
    } noraise {
      _ => fail("expected execute on a bound statement to raise")
    }
  })
}

///|
async test "cached statement is re-prepared on a fresh connection" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    let stmt = db.prepare("UPDATE answers SET answer = ?")
    ignore(stmt.execute())
    assert_eq(connector.conns[0].prepare_count, 1)
    // the connection dies; the next execute retries on a fresh
    // connection and re-prepares the statement there
    connector.conns[0].fail_exec = Some(@driver.BadConn(Failure("exec failed")))
    ignore(stmt.execute())
    @async.sleep(15)
    assert_true(connector.conns[0].closed)
    assert_eq(connector.stats.connect_count, 2)
    assert_eq(connector.conns[1].prepare_count, 1)
    stmt.close()
  })
}

///|
async test "prepared statement query reuses the cached statement" {
  let connector = MockConnector()
  run_db(@sql.DB::new(connector), db => {
    let stmt = db.prepare("SELECT answer FROM answers")
    let rows = stmt.query()
    assert_true(rows.next() is Some(_))
    rows.close()
    // closing the rows keeps the cached statement open for reuse
    let rows2 = stmt.query()
    rows2.close()
    assert_eq(connector.conns[0].prepare_count, 1)
    stmt.close()
  })
}
