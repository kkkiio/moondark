///|
priv struct MockAnswerDBRows {
  mut index : Int32
  stats : MockStats
  count : Int32
}

///|
impl @driver.Rows for MockAnswerDBRows with fn columns(self) {
  ignore(self)
  ["question", "answer"]
}

///|
impl @driver.Rows for MockAnswerDBRows with fn next(self, dest) {
  if self.stats.next_error is Some(e) {
    raise e
  }
  guard self.index < self.count else { return false }
  dest[0] = @driver.Value::String(
    "Answer to the Ultimate Question of Life, the Universe, and Everything",
  )
  dest[1] = @driver.Value::String("42")
  self.index += 1
  true
}

///|
impl @driver.Rows for MockAnswerDBRows with fn close(self) {
  @async.sleep(2)
  self.stats.rows_closed += 1
  if self.stats.fail_cleanup is Some(e) {
    raise e
  }
}

///|
priv struct MockStats {
  mut connect_count : Int32
  mut close_count : Int32
  mut commit_count : Int32
  mut rollback_count : Int32
  mut rows_closed : Int32
  mut statements_closed : Int32
  mut exec_count : Int32
  mut next_error : Error?
  mut fail_cleanup : Error?
}

///|
/// Connector creating a fresh `MockConn` on every `connect`, recording
/// per-connection state so tests can observe pool health validation.
/// `fail_exec` is copied into every new connection so tests can also
/// make the fresh connections used by retries fail.
priv struct MockConnector {
  stats : MockStats
  conns : Array[MockConn]
  mut fail_connect : Error?
  mut connect_delay : Int32
  mut fail_ready : Error?
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
      rows_closed: 0,
      statements_closed: 0,
      exec_count: 0,
      next_error: None,
      fail_cleanup: None,
    },
    conns: [],
    fail_connect: None,
    connect_delay: 0,
    fail_ready: None,
    fail_exec: None,
  }
}

///|
impl @driver.Connector for MockConnector with fn connect(self) {
  self.stats.connect_count += 1
  if self.connect_delay > 0 {
    @async.sleep(self.connect_delay)
  }
  if self.fail_connect is Some(e) {
    raise e
  }
  let conn = MockConn::{
    stats: self.stats,
    closed: false,
    valid: true,
    fail_reset: false,
    fail_ping: false,
    fail_ready: self.fail_ready,
    fail_exec: self.fail_exec,
    fail_begin: None,
    fail_prepare: None,
    reset_count: 0,
    ping_count: 0,
    prepare_count: 0,
    row_count: 1,
    arity: -1,
  }
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
  fail_ready : Error?
  mut fail_exec : Error?
  mut fail_begin : Error?
  mut fail_prepare : Error?
  mut reset_count : Int32
  mut ping_count : Int32
  mut prepare_count : Int32
  mut row_count : Int32
  mut arity : Int32
}

///|
impl @driver.Conn for MockConn with fn prepare(self, _query) {
  self.prepare_count += 1
  if self.fail_prepare is Some(e) {
    raise e
  }
  MockStmt::{ conn: self, executed: [], }
}

///|
impl @driver.Conn for MockConn with fn close(self) {
  self.closed = true
  self.stats.close_count += 1
}

///|
impl @driver.Conn for MockConn with fn ready(self) {
  if self.fail_ready is Some(e) {
    raise e
  }
}

///|
impl @driver.Conn for MockConn with fn begin(self) {
  if self.fail_begin is Some(e) {
    raise e
  }
  MockTx::{ stats: self.stats, }
}

///|
impl @driver.Conn for MockConn with fn batch_execute(_self, _script) {
  fail("not supported")
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
  @async.sleep(2)
  self.conn.stats.statements_closed += 1
  if self.conn.stats.fail_cleanup is Some(e) {
    raise e
  }
}

///|
impl @driver.Stmt for MockStmt with fn num_input(self) {
  self.conn.arity
}

///|
impl @driver.Stmt for MockStmt with fn exec(self, args) {
  if self.conn.fail_exec is Some(e) {
    raise e
  }
  self.conn.stats.exec_count += 1
  self.executed.push(args.to_owned())
  @driver.ExecResult::{ rows_affected: Some(1), last_insert_id: None, }
}

///|
impl @driver.Stmt for MockStmt with fn query(self, _args) {
  MockAnswerDBRows::{
    index: 0,
    stats: self.conn.stats,
    count: self.conn.row_count,
  }
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
  @async.sleep(2)
  self.stats.rollback_count += 1
  if self.stats.fail_cleanup is Some(e) {
    raise e
  }
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
  pair : (@database.DB, @database.DBExecutor),
  f : async (@database.DB) -> Unit,
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
  run_db(@database.DB::create(MockConnector()), db => db.ping())
}

///|
async test "connection failure preserves the driver error and frees capacity" {
  let connector = MockConnector()
  connector.fail_connect = Some(Failure("connection refused"))
  run_db(@database.DB::create(connector, max_open=1), db => {
    try db.ping() catch {
      e => assert_true(e is Failure("connection refused"))
    } noraise {
      _ => fail("expected connection failure")
    }
    assert_eq(connector.stats.connect_count, 1)
    assert_eq(connector.stats.close_count, 0)
    assert_eq(connector.conns.length(), 0)
    assert_eq(db.stats().open, 0)
    assert_eq(db.stats().in_use, 0)
    connector.fail_connect = None
    db.ping()
    assert_eq(connector.stats.connect_count, 2)
    assert_eq(connector.conns[0].ping_count, 1)
    assert_eq(db.stats().idle, 1)
  })
}

///|
async test "handshake failure preserves the driver error and closes the connection" {
  let connector = MockConnector()
  connector.fail_ready = Some(Failure("authentication failed"))
  run_db(@database.DB::create(connector, max_open=1), db => {
    try db.ping() catch {
      e => assert_true(e is Failure("authentication failed"))
    } noraise {
      _ => fail("expected handshake failure")
    }
    assert_eq(connector.stats.connect_count, 1)
    assert_eq(connector.stats.close_count, 1)
    assert_true(connector.conns[0].closed)
    assert_eq(connector.conns[0].ping_count, 0)
    assert_eq(db.stats().open, 0)
    assert_eq(db.stats().in_use, 0)
    connector.fail_ready = None
    db.ping()
    assert_eq(connector.stats.connect_count, 2)
    assert_eq(connector.conns[1].ping_count, 1)
    assert_eq(db.stats().idle, 1)
  })
}

///|
async test "reset_session runs before returning a connection to the pool" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector), db => {
    db.ping()
    db.ping()
    assert_eq(connector.stats.connect_count, 1)
    assert_eq(connector.conns[0].reset_count, 2)
    assert_eq(connector.conns[0].ping_count, 2)
  })
}

///|
async test "idle connection failing is_valid is discarded" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector), db => {
    db.ping()
    connector.conns[0].valid = false
    db.ping()
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
  run_db(@database.DB::create(connector), db => {
    db.ping()
    connector.conns[0].fail_reset = true
    db.ping()
    db.ping()
    @async.sleep(15)
    assert_eq(connector.stats.connect_count, 2)
    assert_eq(connector.conns[0].reset_count, 2)
    assert_true(connector.conns[0].closed)
    assert_eq(connector.conns[1].ping_count, 1)
  })
}

///|
async test "ping raising BadConn discards the connection and retries" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector), db => {
    db.ping()
    connector.conns[0].fail_ping = true
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
  run_db(@database.DB::create(connector, max_idle=1, max_open=1), db => {
    db.ping()
    connector.conns[0].fail_ping = true
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
  run_db(@database.DB::create(connector), db => {
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
  run_db(@database.DB::create(connector), db => {
    try db.execute("INSERT INTO t VALUES (1)") catch {
      e => assert_true(e is @driver.BadConn(_))
    } noraise {
      _ => fail("expected execute to raise BadConn")
    }
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
  run_db(@database.DB::create(connector), db => {
    db.ping()
    connector.conns[0].fail_exec = Some(Failure("syntax error"))
    try db.execute("INSERT INTO t VALUES (1)") catch {
      e => assert_true(e is Failure(_))
    } noraise {
      _ => fail("expected execute to fail")
    }
    assert_eq(connector.stats.connect_count, 1)
    assert_true(!connector.conns[0].closed)
  })
}

///|
async test "with_transaction rolls back and does not retry when f fails" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector), db => {
    let f : async (@database.Transaction) -> Unit = tx => {
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
  run_db(
    @database.DB::create(
      connector,
      max_lifetime=@time.Duration::of(nanoseconds=1),
    ),
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
    @database.DB::create(
      connector,
      max_idle_time=@time.Duration::of(nanoseconds=1),
    ),
    db => {
      db.ping()
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
    @database.DB::create(
      connector,
      max_lifetime=@time.Duration::of(nanoseconds=1),
    ),
    db => {
      db.with_stream("SELECT 1", _ => @async.sleep(15))
      @async.sleep(15)
      assert_true(connector.conns[0].closed)
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
  run_db(@database.DB::create(connector), db => {
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
  run_db(@database.DB::create(connector), db => {
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
    @database.DB::create(
      connector,
      max_lifetime=@time.Duration::of(nanoseconds=1),
    ),
    db => {
      db.ping()
      @async.sleep(15)
      db.ping()
      assert_eq(db.stats().max_lifetime_closed, 1)
    },
  )
}

///|
async test "stats counts connections closed for exceeding max_idle_time" {
  let connector = MockConnector()
  run_db(
    @database.DB::create(
      connector,
      max_idle_time=@time.Duration::of(nanoseconds=1),
    ),
    db => {
      db.ping()
      @async.sleep(15)
      db.ping()
      assert_eq(db.stats().max_idle_time_closed, 1)
      assert_eq(db.stats().max_lifetime_closed, 0)
    },
  )
}

///|
async test "stats counts connections closed when the idle queue is full" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_idle=0), db => {
    db.ping()
    let stats = db.stats()
    assert_eq(stats.max_idle_closed, 1)
    assert_eq(stats.open, 0)
    assert_eq(stats.in_use, 0)
    assert_eq(stats.idle, 0)
  })
}
