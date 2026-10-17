///|
pub(open) trait Driver {
  fn open(Self, String) -> &Connector raise
}

///|
pub(open) trait Connector {
  /// Open a new physical connection together with the executor driving
  /// its protocol. The pool spawns the executor on its own task group;
  /// callers only ever see the connection half of the pair.
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
/// An error raised by a driver to signal that the connection is no longer
/// usable. The pool discards the connection; when raised before the
/// operation was sent to the server, the operation may be retried on a new
/// connection. Carries the underlying error.
pub(all) suberror BadConn {
  BadConn(Error)
}

///|
pub(open) trait Conn {
  async fn prepare(Self, String) -> &Stmt
  async fn close(Self) -> Unit
  async fn begin(Self) -> &Tx
  /// ResetSession is called prior to executing a query on the connection
  /// if the connection has been used before. If the driver returns ErrBadConn
  /// the connection is discarded.
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
  async fn ready(Self) -> Unit = _
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
  fn num_input(Self) -> Int32
  async fn exec(Self, Array[Value]) -> ExecResult
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
