///|
pub(open) trait Driver {
  fn open(Self, String) -> &Connector raise
}

///|
pub(open) trait Connector {
  /// Open a new physical connection together with the executor driving
  /// its protocol. The pool spawns the executor on its own task group;
  /// callers only ever see the connection half of the pair.
  /// Establishment failures must raise the original error rather than
  /// `BadConn`; the pool propagates them directly to the caller.
  async fn connect(Self) -> (&Conn, &ConnExecutor)
}

///|
/// A long-running background task that drives a connection's wire protocol.
/// Drivers whose connections need a dedicated task (e.g. network protocol
/// clients) return their own executor from `Connector::connect`; drivers
/// whose connections are self-sufficient return `@driver.NoopExecutor`.
pub(open) trait ConnExecutor {
  /// Drive the connection's protocol loop until the connection is closed
  /// or the executor is cancelled. Called exactly once by the pool, on the
  /// pool's task group.
  async fn run(Self) -> Unit
}

///|
/// Executor for drivers whose connections need no background task. `run`
/// returns immediately.
pub(all) struct NoopExecutor {}

///|
pub impl ConnExecutor for NoopExecutor with fn run(_self) {
  ()
}

///|
pub extend NoopExecutor with ConnExecutor::{run}

///|
/// An error carrying the underlying cause when an existing connection is
/// unusable and the current operation can safely be retried on another
/// connection. Drivers must only raise it when the server could not have
/// executed the operation. The pool discards the connection and may retry.
pub(all) suberror BadConn {
  BadConn(Error)
}

///|
/// A physical database connection.
///
/// SQL text flows into a driver through `prepare` verbatim. Like Go's
/// `database/sql` and Rust's `sqlx`, `database/sql` does not define a
/// canonical placeholder syntax and never rewrites SQL: parameters use
/// the backend's native markers (`?` for SQLite and MySQL, `$1`, `$2`,
/// … for PostgreSQL), and drivers must pass the text to the server
/// unchanged. Code that targets several backends writes one statement
/// per backend.
/// Context: https://github.com/golang/go/issues/3602.
pub(open) trait Conn {
  /// Prepare `sql` for repeated execution on this connection. `sql`
  /// uses the backend's native placeholders.
  async fn prepare(Self, String) -> &Stmt
  async fn close(Self) -> Unit
  async fn begin(Self) -> &Tx
  /// `reset_session` is called prior to executing a query on the
  /// connection if the connection has been used before. If the driver
  /// raises `BadConn` the connection is discarded.
  async fn reset_session(Self) -> Unit = _
  /// is_valid is called before reusing a pooled connection that was
  /// previously returned to the pool. Return `false` to have the
  /// connection discarded instead of reused. Default: `true`.
  fn is_valid(Self) -> Bool = _
  /// ping checks that the connection is still alive.
  /// The default implementation does nothing.
  async fn ping(Self) -> Unit = _
  /// Wait until the connection is usable. The pool calls this after the
  /// connection's executor has been spawned. The default implementation
  /// returns immediately: self-sufficient connections are ready as soon
  /// as `connect` returns.
  /// Handshake failures must raise the original error rather than
  /// `BadConn`; the pool closes the connection and propagates the error.
  async fn ready(Self) -> Unit = _
  /// Execute `script` verbatim — the text may contain multiple
  /// statements separated by `;`. No parameters are bound and result
  /// rows are discarded; execution stops at the first failing
  /// statement and raises its error. Only server-side SQL is accepted:
  /// client-tool directives (psql `\i`, mysql `DELIMITER`, sqlcmd
  /// `GO`) are not.
  ///
  /// Transaction semantics are driver-defined and each driver must
  /// document them: PostgreSQL runs the whole script as one implicit
  /// transaction, SQLite commits statement by statement. Drivers
  /// without a multi-statement path raise.
  async fn execute_script(Self, String) -> Unit
}

///|
/// Default implementation of reset_session that does nothing.
impl Conn with fn reset_session(self) {
  ignore(self)
}

///|
/// Default implementation of is_valid that reports the connection as valid.
impl Conn with fn is_valid(self) {
  ignore(self)
  true
}

///|
/// Default implementation of ping that does nothing.
impl Conn with fn ping(self) {
  ignore(self)
}

///|
/// Default implementation of ready that does nothing.
impl Conn with fn ready(self) {
  ignore(self)
}

///|
pub(open) trait Stmt {
  async fn close(Self) -> Unit
  /// The number of parameters the prepared statement takes; `-1` when
  /// the driver cannot determine it and the caller-side arity check is
  /// skipped.
  fn num_input(Self) -> Int32
  /// Run the statement for its side effect. `args` binds to the
  /// statement's parameters in the backend's positional order.
  async fn exec(Self, Array[Value]) -> ExecResult
  /// Run the statement and stream its result rows. `args` binds to the
  /// statement's parameters in the backend's positional order.
  async fn query(Self, Array[Value]) -> &Rows
}

///|
/// The result of executing a statement.
pub(all) struct ExecResult {
  /// `None` if the database did not report a row count (e.g. DDL statements).
  rows_affected : Int64?
  /// `None` if the database does not report generated ids (e.g. PostgreSQL)
  /// or the statement generated none.
  last_insert_id : Int64?
}

///|
pub(open) trait Tx {
  async fn commit(Self) -> Unit
  async fn rollback(Self) -> Unit
}

///|
pub(open) trait Rows {
  fn columns(Self) -> Array[String]
  async fn close(Self) -> Unit
  async fn next(Self, dest : Array[Value]) -> Bool
}

///|
pub(all) enum Value {
  Null
  Bool(Bool)
  Int64(Int64)
  Double(Double)
  String(String)
  Bytes(Bytes)
  Timestamp(@time.ZonedDateTime)
} derive(Debug)

///|
pub extend Value with Debug::{to_repr}

///|
pub(open) trait Valuer {
  fn to_value(Self) -> Value
}

///|
pub impl Valuer for Value with fn to_value(self) -> Value {
  self
}

///|
#deprecated
pub extend Value with Valuer::{to_value}

///|
pub impl Valuer for Bool with fn to_value(self) -> Value {
  Value::Bool(self)
}

///|
pub impl Valuer for Int32 with fn to_value(self) -> Value {
  Value::Int64(self.to_int64())
}

///|
pub impl Valuer for Int64 with fn to_value(self) -> Value {
  Value::Int64(self)
}

///|
pub impl Valuer for Double with fn to_value(self) -> Value {
  Value::Double(self)
}

///|
pub impl Valuer for String with fn to_value(self) -> Value {
  Value::String(self)
}

///|
pub impl Valuer for Bytes with fn to_value(self) -> Value {
  Value::Bytes(self)
}

///|
pub impl Valuer for @time.ZonedDateTime with fn to_value(self) -> Value {
  Value::Timestamp(self)
}
