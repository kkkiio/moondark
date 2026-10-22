///|
/// Open a pooled MySQL database.
///
/// `dsn` accepts either of the shapes a `@mysql.MySqlContainer` handle
/// produces:
///
/// * a MySQL URI — `mysql://user[:password]@host[:port]/database`
///   (`MySqlContainer::connection_string`); user, password and database are
///   percent-decoded.
/// * a Go-style DSN — `user:password@tcp(host:port)/database`
///   (`MySqlContainer::dsn`).
///
/// The port defaults to 3306 and an empty host to `127.0.0.1`. Query
/// parameters and Unix-socket forms are not supported.
///
/// Returns the `DB` and its `DBExecutor`; spawn the executor on a task
/// group that outlives the database:
///
/// ```
/// let (db, executor) = @mysql_database.open_db("mysql://root@127.0.0.1/app")
/// group.spawn_bg(no_wait=true, () => executor.run())
/// ```
pub fn open_db(
  dsn : String,
  max_idle~ : Int32 = 5,
  max_open~ : Int32 = 10,
  max_lifetime~ : @time.Duration = @time.Duration::zero(),
  max_idle_time~ : @time.Duration = @time.Duration::zero(),
) -> (@sql.DB, @sql.DBExecutor) raise {
  @sql.DB::create(
    Driver::new().open(dsn),
    max_idle~,
    max_open~,
    max_lifetime~,
    max_idle_time~,
  )
}

///|
/// MySQL driver implementing `@driver.Driver` on top of MariaDB
/// Connector/C (`libmariadb`) through the `moondark_mysql_*` C FFI:
/// every pooled connection owns an executor whose worker thread runs
/// all libmariadb calls, while MoonBit submits jobs and waits on a
/// completion pipe (`begin`/`commit`/`rollback` therefore bracket a
/// real server-side transaction).
///
/// ```
/// let (db, executor) = @sql.DB::create(@mysql_database.Driver::new().open("mysql://u:p@h/db"))
/// ```
struct Driver {}

///|
pub fn Driver::new() -> Driver {
  Driver::{ }
}

///|
/// `open` only parses and validates the DSN — no network traffic. The
/// real handshake happens per connection in `Connector::connect`.
pub impl @driver.Driver for Driver with fn open(_self, dsn) {
  parse_dsn(dsn)
}

///|
pub extend Driver with @driver.Driver::{open}

///|
struct Connector {
  host : String
  port : Int32
  user : String
  password : String
  database : String
}

///|
/// Parse the DSN eagerly so a malformed string fails in `open` rather
/// than on the first pooled connect.
fn parse_dsn(dsn : String) -> Connector raise {
  if dsn.has_prefix("mysql://") {
    return parse_uri_dsn(dsn)
  }
  parse_go_dsn(dsn)
}

///|
/// `mysql://user[:password]@host[:port]/database`. The userinfo/host
/// split uses the last `@` before the path (a literal `@` inside
/// credentials is percent-encoded by producers); IPv6 hosts keep their
/// `[…]` brackets.
fn parse_uri_dsn(dsn : String) -> Connector raise {
  let body = dsn[8:]
  guard body.find("/") is Some(slash) else {
    fail("malformed MySQL DSN '\{dsn}': missing /database")
  }
  let authority = body[:slash]
  let database = decode_part(body[slash + 1:])
  guard authority.rev_find("@") is Some(at) else {
    fail("malformed MySQL DSN '\{dsn}': missing user@")
  }
  let userinfo = authority[:at]
  let hostport = authority[at + 1:]
  let (user, password) = match userinfo.find(":") {
    Some(i) => (decode_part(userinfo[:i]), decode_part(userinfo[i + 1:]))
    None => (decode_part(userinfo), "")
  }
  let (host, port) = parse_host_port(hostport, dsn)
  Connector::{ host, port, user, password, database, }
}

///|
/// Go-style `user:password@tcp(host:port)/database` used by
/// go-sql-driver and emitted by `MySqlContainer::dsn`. Values are
/// taken verbatim (this form is not percent-encoded).
fn parse_go_dsn(dsn : String) -> Connector raise {
  guard dsn.find("@tcp(") is Some(at) else {
    fail(
      "malformed MySQL DSN '\{dsn}': expected mysql://user[:password]@host[:port]/db or user:password@tcp(host:port)/db",
    )
  }
  let userinfo = dsn[:at]
  let rest = dsn[at + 5:]
  guard rest.find(")") is Some(close) else {
    fail("malformed MySQL DSN '\{dsn}': unclosed tcp(…)")
  }
  let hostport = rest[:close]
  let path = rest[close + 1:]
  let database = if path.has_prefix("/") {
    path[1:].to_owned()
  } else {
    path.to_owned()
  }
  let (user, password) = match userinfo.find(":") {
    Some(i) => (userinfo[:i].to_owned(), userinfo[i + 1:].to_owned())
    None => (userinfo.to_owned(), "")
  }
  let (host, port) = parse_host_port(hostport, dsn)
  Connector::{ host, port, user, password, database, }
}

///|
/// Percent-decode one DSN component; a malformed `%` sequence keeps
/// the raw text rather than failing the whole DSN.
fn decode_part(part : StringView) -> String {
  @percent.decode(part) catch {
    _ => part.to_owned()
  }
}

///|
/// Split `host[:port]` honouring `[ipv6]` brackets; empty host falls
/// back to `127.0.0.1`, missing port to 3306.
fn parse_host_port(
  hostport : StringView,
  dsn : String,
) -> (String, Int32) raise {
  if hostport.has_prefix("[") {
    guard hostport.find("]") is Some(close) else {
      fail("malformed MySQL DSN '\{dsn}': unclosed [ipv6]")
    }
    let host = hostport[1:close].to_owned()
    let rest = hostport[close + 1:]
    let port = if rest.has_prefix(":") {
      parse_port(rest[1:], dsn)
    } else {
      3306
    }
    return (host, port)
  }
  match hostport.rev_find(":") {
    Some(i) =>
      (
        if i == 0 {
          "127.0.0.1"
        } else {
          hostport[:i].to_owned()
        },
        parse_port(hostport[i + 1:], dsn),
      )
    None =>
      (if hostport == "" { "127.0.0.1" } else { hostport.to_owned() }, 3306)
  }
}

///|
fn parse_port(text : StringView, dsn : String) -> Int32 raise {
  let port = @string.parse_int(text) catch {
    _ => fail("malformed MySQL DSN '\{dsn}': bad port '\{text}'")
  }
  guard port > 0 && port <= 65535 else {
    fail("malformed MySQL DSN '\{dsn}': port out of range '\{text}'")
  }
  port
}

///|
/// `connect` brings up one executor (its worker thread runs all
/// libmariadb calls for the connection) and performs the handshake
/// through a connect job. Client-side errnos (CR_*, 2000..<3000)
/// surface as `BadConn` so the pool may retry acquisition; server-side
/// failures carry `SQLSTATE message` and propagate as plain errors.
/// The pair's second half is a `@driver.NoopExecutor`: the C worker
/// thread needs no MoonBit-side runner.
pub impl @driver.Connector for Connector with fn connect(self) {
  if mysql_library_init() != 0 {
    fail("mysql: mysql_library_init failed")
  }
  let rescode = Ref(0)
  let executor = mysql_executor_create(rescode)
  if rescode.val != 0 {
    fail("mysql: failed to create executor (code \{rescode.val})")
  }
  let mut executor_owned = true
  defer (if executor_owned { mysql_executor_release(executor) })
  let job = connect_job(
    executor,
    @utf8.encode(self.host[:]),
    self.port,
    @utf8.encode(self.user[:]),
    @utf8.encode(self.password[:]),
    @utf8.encode(self.database[:]),
    rescode,
  )
  defer job.release()
  if rescode.val != 0 {
    fail("mysql: failed to submit connect job (code \{rescode.val})")
  }
  job.wait()
  let errno = job.errno()
  if errno != 0 {
    let error = job.error()
    if errno >= 2000 && errno < 3000 {
      raise @driver.BadConn(error)
    }
    raise error
  }
  executor_owned = false
  (
    (
      Conn::{ inner: job.take_conn(), executor, alive: true, closed: false, } :
      &@driver.Conn),
    @driver.NoopExecutor::{ },
  )
}

///|
pub extend Connector with @driver.Connector::{connect}

///|
struct Conn {
  inner : MysqlConn
  executor : MysqlExecutor
  /// Whether the connection is believed usable; cleared on client-side
  /// job errors (`check`) or by `close`.
  mut alive : Bool
  /// Whether teardown already ran; `close` must free the C resources
  /// even when `alive` is already false, so the two are tracked
  /// separately.
  mut closed : Bool
}

///|
/// Run a no-parameter statement through a query job and raise the
/// job's error on failure.
async fn Conn::run_query(self : Conn, sql : String) -> Unit {
  let rescode = Ref(0)
  let job = query_job(self.executor, self.inner, @utf8.encode(sql[:]), rescode)
  defer job.release()
  if rescode.val != 0 {
    fail("mysql: failed to submit query job (code \{rescode.val})")
  }
  job.wait()
  self.check(job)
}

///|
/// Raise a completed job's failure: client-side errnos
/// (2000..<3000) mark the connection dead and become `BadConn`;
/// everything else propagates as a plain `SQLSTATE message` error.
fn Conn::check(self : Conn, job : AsyncJob) -> Unit raise {
  let errno = job.errno()
  if errno == 0 {
    return
  }
  let error = job.error()
  if errno >= 2000 && errno < 3000 {
    self.alive = false
    raise @driver.BadConn(error)
  }
  raise error
}

///|
/// `prepare` submits a `mysql_stmt_prepare` job; the returned
/// statement borrows the connection's executor for all later jobs.
pub impl @driver.Conn for Conn with fn prepare(self, sql) {
  let rescode = Ref(0)
  let job = prepare_job(
    self.executor,
    self.inner,
    @utf8.encode(sql[:]),
    rescode,
  )
  defer job.release()
  if rescode.val != 0 {
    fail("mysql: failed to submit prepare job (code \{rescode.val})")
  }
  job.wait()
  self.check(job)
  (
    Stmt::{
      inner: job.take_stmt(),
      conn: self,
      num_input: job.param_count(),
      closed: false,
    } : &@driver.Stmt)
}

///|
/// `close` submits a conn-close job (`mysql_close` on the worker) and
/// then tears the executor down — the worker joins with every libmariadb
/// object already freed. Runs even for a connection marked dead by a
/// client-side error: teardown is what frees the `MYSQL` handle and
/// joins the worker thread. Idempotent via `closed`.
pub impl @driver.Conn for Conn with fn close(self) {
  if self.closed {
    return
  }
  self.closed = true
  self.alive = false
  let rescode = Ref(0)
  let job = conn_close_job(self.executor, self.inner, rescode)
  defer job.release()
  if rescode.val == 0 {
    job.wait()
  }
  mysql_executor_release(self.executor)
  if rescode.val != 0 {
    fail("mysql: failed to submit conn close job (code \{rescode.val})")
  }
  if job.errno() != 0 {
    raise job.error()
  }
}

///|
/// `begin` runs `BEGIN` through a query job; `Tx::commit` and
/// `Tx::rollback` issue `COMMIT`/`ROLLBACK` the same way.
pub impl @driver.Conn for Conn with fn begin(self) {
  self.run_query("BEGIN")
  Tx::{ conn: self, }
}

///|
/// The connection stays valid until `close` or until a job reports a
/// client-side (BadConn-class) errno.
pub impl @driver.Conn for Conn with fn is_valid(self) {
  self.alive
}

///|
/// `ping` submits a `mysql_ping` job to verify the connection is
/// still alive. A dead connection reports a client-side errno, which
/// `check` turns into `BadConn` so the pool discards it.
pub impl @driver.Conn for Conn with fn ping(self) {
  let rescode = Ref(0)
  let job = ping_job(self.executor, self.inner, rescode)
  defer job.release()
  if rescode.val != 0 {
    fail("mysql: failed to submit ping job (code \{rescode.val})")
  }
  job.wait()
  self.check(job)
}

///|
/// `reset_session` rolls back any transaction left open on a reused
/// pooled connection. It is deliberately a `ROLLBACK`, not
/// `mysql_reset_connection`: the latter releases server-side prepared
/// statements, which would invalidate the pool's per-connection
/// statement cache.
pub impl @driver.Conn for Conn with fn reset_session(self) {
  let rescode = Ref(0)
  let job = reset_job(self.executor, self.inner, rescode)
  defer job.release()
  if rescode.val != 0 {
    fail("mysql: failed to submit reset job (code \{rescode.val})")
  }
  job.wait()
  self.check(job)
}

///|
/// `execute_script` sends the whole script through one query job;
/// `CLIENT_MULTI_STATEMENTS` is negotiated at connect time and the
/// worker drains every result set. Statements execute in sequence —
/// there is no implicit transaction, so statements before a failing
/// one stay committed.
pub impl @driver.Conn for Conn with fn execute_script(self, script) {
  self.run_query(script)
}

///|
pub extend Conn with @driver.Conn::{
  begin,
  close,
  prepare,
  is_valid,
  ping,
  ready,
  reset_session,
  execute_script,
}

///|
struct Tx {
  conn : Conn
}

///|
pub impl @driver.Tx for Tx with fn commit(self) {
  self.conn.run_query("COMMIT")
}

///|
pub impl @driver.Tx for Tx with fn rollback(self) {
  self.conn.run_query("ROLLBACK")
}

///|
pub extend Tx with @driver.Tx::{commit, rollback}

///|
struct Stmt {
  inner : MysqlStmt
  conn : Conn
  num_input : Int32
  mut closed : Bool
}

///|
/// Fill the exec job's parameter binds from `args`, in positional
/// order: `Timestamp` binds as epoch microseconds UTC (worker renders
/// `MYSQL_TYPE_DATETIME`).
fn bind_args(job : AsyncJob, args : Array[@driver.Value]) -> Unit {
  for i, arg in args {
    match arg {
      Null => job.bind_null(i)
      Bool(b) => job.bind_bool(i, b)
      Int64(v) => job.bind_int64(i, v)
      Double(v) => job.bind_double(i, v)
      String(v) => job.bind_string(i, @utf8.encode(v[:]))
      Bytes(v) => job.bind_blob(i, v)
      Timestamp(zdt) =>
        job.bind_timestamp(
          i,
          zdt.to_unix_second() * 1_000_000 + zdt.nanosecond().to_int64() / 1_000,
        )
    }
  }
}

///|
/// Run the shared exec job — create, bind parameters, submit to the
/// worker (it executes and, for result-set statements, stores the
/// result plus column metadata), then wait for completion.
async fn Stmt::submit_exec(
  self : Stmt,
  args : Array[@driver.Value],
) -> AsyncJob {
  let rescode = Ref(0)
  let job = exec_job(self.conn.executor, self.inner, rescode)
  errdefer job.release()
  if rescode.val != 0 {
    fail("mysql: failed to create exec job (code \{rescode.val})")
  }
  bind_args(job, args)
  job.submit(rescode)
  if rescode.val != 0 {
    fail("mysql: failed to submit exec job (code \{rescode.val})")
  }
  job.wait()
  job
}

///|
/// `close` submits a stmt-close job (`mysql_stmt_close` on the
/// worker); guarded by `closed` so `Rows::close` and `Stmt::close`
/// cannot double-close the wrapper.
pub impl @driver.Stmt for Stmt with fn close(self) {
  if self.closed {
    return
  }
  self.closed = true
  let rescode = Ref(0)
  let job = stmt_close_job(self.conn.executor, self.inner, rescode)
  defer job.release()
  if rescode.val != 0 {
    fail("mysql: failed to submit stmt close job (code \{rescode.val})")
  }
  job.wait()
  self.conn.check(job)
}

///|
/// The `?` placeholder count reported by `mysql_stmt_param_count` at
/// prepare time.
pub impl @driver.Stmt for Stmt with fn num_input(self) {
  self.num_input
}

///|
pub impl @driver.Stmt for Stmt with fn exec(self, args) {
  let job = self.submit_exec(args)
  defer job.release()
  self.conn.check(job)
  let rows_affected = job.affected_rows()
  let last_insert_id = job.insert_id()
  {
    rows_affected: if rows_affected < 0 {
      None
    } else {
      Some(rows_affected)
    },
    last_insert_id: if last_insert_id == 0 {
      None
    } else {
      Some(last_insert_id)
    },
  }
}

///|
/// `query` runs the same exec job as `exec`; when the statement
/// produced a result set the worker stored it and snapshotted the
/// column metadata, so `columns()` is correct even for an empty
/// result and each `Rows::next` fetches one buffered row.
pub impl @driver.Stmt for Stmt with fn query(self, args) {
  let job = self.submit_exec(args)
  defer job.release()
  self.conn.check(job)
  let columns = []
  if job.has_result() {
    for i in 0..<self.inner.col_count() {
      columns.push(self.inner.col_name(i))
    }
  }
  (Rows::{ stmt: self, columns, } : &@driver.Rows)
}

///|
pub extend Stmt with @driver.Stmt::{close, num_input, exec, query}

///|
struct Rows {
  stmt : Stmt
  columns : Array[String]
}

///|
pub impl @driver.Rows for Rows with fn columns(self) {
  self.columns
}

///|
/// `next` submits a fetch job and copies the row into `dest`, mapping
/// each column by its `kind` code: 1 → `Int64`, 2 → `Double`,
/// 3 → `String` (lossy UTF-8), 4 → `Bytes`, 5 → `Timestamp` in UTC.
/// NULL columns yield `Null`, as do columns beyond the result width.
pub impl @driver.Rows for Rows with fn next(self, dest) {
  if self.stmt.closed || self.columns.is_empty() {
    return false
  }
  let rescode = Ref(0)
  let job = fetch_job(self.stmt.conn.executor, self.stmt.inner, rescode)
  defer job.release()
  if rescode.val != 0 {
    fail("mysql: failed to submit fetch job (code \{rescode.val})")
  }
  job.wait()
  self.stmt.conn.check(job)
  guard job.has_row() else { return false }
  let ncols = self.stmt.inner.col_count()
  for i in 0..<dest.length() {
    dest[i] = if i >= ncols || job.col_is_null(i) {
      Null
    } else {
      match self.stmt.inner.col_kind(i) {
        1 => Int64(job.col_i64(i))
        2 => Double(job.col_double(i))
        3 => String(@utf8.decode_lossy(job.col_bytes(i)[:]))
        4 => Bytes(job.col_bytes(i))
        5 => {
          let micros = job.col_time_micros(i)
          let rem = micros % 1_000_000
          let (second, nanosecond) = if rem < 0 {
            (micros / 1_000_000 - 1, (rem + 1_000_000) * 1_000)
          } else {
            (micros / 1_000_000, rem * 1_000)
          }
          Timestamp(
            @time.ZonedDateTime::from_unix_second(
              second,
              nanosecond=nanosecond.to_int(),
              zone=@time.utc_zone,
            ),
          )
        }
        _ => Bytes(job.col_bytes(i))
      }
    }
  }
  true
}

///|
/// `close` releases only the current result set
/// (`mysql_stmt_free_result` on the worker), never the statement:
/// `database/sql` caches driver statements per pooled connection, so
/// statement lifetime belongs to `Stmt::close` — closing it here
/// would leave the cache holding a freed handle.
pub impl @driver.Rows for Rows with fn close(self) {
  if self.stmt.closed {
    return
  }
  let rescode = Ref(0)
  let job = result_close_job(self.stmt.conn.executor, self.stmt.inner, rescode)
  defer job.release()
  if rescode.val != 0 {
    fail("mysql: failed to submit result close job (code \{rescode.val})")
  }
  job.wait()
  self.stmt.conn.check(job)
}

///|
pub extend Rows with @driver.Rows::{close, columns, next}
