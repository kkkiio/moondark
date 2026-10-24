///|
/// Backend factory that parses a data source name into a reusable `Connector`.
pub(open) trait Driver {
  fn open(Self, String) -> &Connector raise
}

///|
/// Factory that establishes physical connections paired with their wire-protocol executor.
pub(open) trait Connector {
  /// Open a new physical connection and its background protocol executor.
  /// Establishment failures must raise the original error rather than `BadConn`.
  async fn connect(Self) -> (&Conn, &ConnExecutor)
}

///|
/// Long-running background task driving one physical connection's wire protocol.
pub(open) trait ConnExecutor {
  /// Drive the connection's protocol loop until closed or cancelled.
  async fn run(Self) -> Unit
}

///|
/// No-op executor for in-process drivers (such as SQLite) that need no background loop.
pub(all) struct NoopExecutor {}

///|
pub impl ConnExecutor for NoopExecutor with fn run(_self) {
  ()
}

///|
pub extend NoopExecutor with ConnExecutor::{run}

///|
/// Error wrapper indicating a connection died before the operation reached the server,
/// allowing the pool to discard the connection and safely retry on a fresh one.
pub(all) suberror BadConn {
  BadConn(Error)
}

///|
pub impl Show for BadConn with fn to_string(self) {
  match self {
    BadConn(e) => "BadConn(\{e})"
  }
}

///|
pub extend BadConn with Show::{to_string, output}

///|
/// A single physical database connection managed by the pool.
///
/// SQL text is passed verbatim using the backend's native placeholders
/// (`?` for SQLite, `$1, $2, ...` for PostgreSQL).
pub(open) trait Conn {
  /// Prepare `sql` for execution on this connection.
  async fn prepare(Self, String) -> &Stmt
  /// Close the physical connection and release its transport resources.
  async fn close(Self) -> Unit
  /// Begin a transaction on this connection.
  async fn begin(Self) -> &Tx
  /// Reset session state before returning the connection to the idle pool.
  async fn reset_session(Self) -> Unit = _
  /// Report whether the connection is still usable when checked out from the pool.
  fn is_valid(Self) -> Bool = _
  /// Verify liveness of the underlying connection.
  async fn ping(Self) -> Unit = _
  /// Wait until transport, TLS, and authentication handshakes complete.
  async fn ready(Self) -> Unit = _
  /// Execute a multi-statement server-side SQL batch without parameters.
  /// Client-tool directives (such as psql `\i` or MySQL `DELIMITER`) are not supported;
  /// transaction semantics follow the backend (implicit transaction on PostgreSQL,
  /// statement-by-statement on SQLite).
  async fn batch_execute(Self, String) -> Unit
}

///|
impl Conn with fn reset_session(self) {
  ignore(self)
}

///|
impl Conn with fn is_valid(self) {
  ignore(self)
  true
}

///|
impl Conn with fn ping(self) {
  ignore(self)
}

///|
impl Conn with fn ready(self) {
  ignore(self)
}

///|
/// A prepared statement bound to a single physical `@driver.Conn`.
pub(open) trait Stmt {
  /// Close the prepared statement on the backend.
  async fn close(Self) -> Unit
  /// Expected parameter count, or `-1` if the driver does not report it.
  fn num_input(Self) -> Int32
  /// Execute the statement for its side effects and return row count metadata.
  async fn exec(Self, ArrayView[Value]) -> ExecResult
  /// Execute the statement and return a cursor over its result rows.
  async fn query(Self, ArrayView[Value]) -> &Rows
}

///|
/// Summary of a side-effecting SQL execution.
pub(all) struct ExecResult {
  /// Number of rows affected, or `None` for statements without a row count (e.g. DDL).
  rows_affected : Int64?
  /// Database-generated row ID when supported (e.g. SQLite `last_insert_rowid()`), else `None`.
  last_insert_id : Int64?
} derive(Eq, Debug)

///|
pub extend ExecResult with Eq::{equal, not_equal}

///|
pub extend ExecResult with Debug::{to_repr}

///|
/// An active transaction on a physical `@driver.Conn`.
pub(open) trait Tx {
  async fn commit(Self) -> Unit
  async fn rollback(Self) -> Unit
}

///|
/// Result cursor produced by `@driver.Stmt::query`.
pub(open) trait Rows {
  /// Column names of the result set in positional order.
  fn columns(Self) -> ArrayView[String]
  /// Drain and close the result cursor.
  async fn close(Self) -> Unit
  /// Populate `dest` with the next row's values; returns `false` at EOF.
  async fn next(Self, dest : Array[Value]) -> Bool
}

///|
/// Backend-neutral scalar value exchanged between `database` and a driver.
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
