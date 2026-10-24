///|
pub using @driver {type ExecResult, type Value}

///|
/// Errors raised by `database` pool, scope, parameter, and row decoding operations.
pub(all) suberror DatabaseError {
  /// Operation attempted on a closed `DB`, `Conn`, `Transaction`, or `RowStream`.
  Closed(String)
  /// Handle used after its `with_conn`, `with_transaction`, `with_prepared`, or `with_stream` callback returned.
  ScopeExpired
  /// `DBExecutor::run` was called more than once.
  ExecutorAlreadyStarted
  /// Supplied parameter count did not match the prepared statement's expected count.
  ArityMismatch(expected~ : Int32, actual~ : Int32)
  /// `query_one` or `query_opt` observed an unexpected number of rows.
  RowCount(String)
  /// Named column lookup failed on a `Row`.
  ColumnNotFound(String)
  /// Column value could not be decoded into the requested MoonBit type.
  Decode(expected~ : String, actual~ : Value)
} derive(Debug)

///|
pub extend DatabaseError with Debug::{to_repr}

///|
/// Common query and execution operations shared by `DB`, `Conn`, and `Transaction`.
pub(open) trait GenericClient {
  /// Execute `sql` and collect all result rows into an array.
  async fn query_all(Self, String, params? : ArrayView[&ToSql]) -> Array[Row]
  /// Execute `sql` and return its single row; raises `DatabaseError::RowCount` if zero or multiple rows are returned.
  async fn query_one(Self, String, params? : ArrayView[&ToSql]) -> Row
  /// Execute `sql` and return `Some(row)` or `None`; raises `DatabaseError::RowCount` if more than one row is returned.
  async fn query_opt(Self, String, params? : ArrayView[&ToSql]) -> Row?
  /// Execute a statement for its side effects and return row count metadata.
  async fn execute(Self, String, params? : ArrayView[&ToSql]) -> ExecResult
  /// Execute a multi-statement SQL script without parameters.
  async fn batch_execute(Self, String) -> Unit
  /// Verify that the underlying database connection is alive.
  async fn ping(Self) -> Unit
}

///|
/// Snapshot of connection pool statistics.
pub struct DBStats {
  /// Maximum number of open connections (`max_open`).
  max_open : Int32
  /// Total connections managed by the pool (`in_use + idle`).
  open : Int32
  /// Connections currently checked out.
  in_use : Int32
  /// Connections sitting idle in the pool.
  idle : Int32
  /// Cumulative number of times a caller waited for a connection.
  wait_count : Int64
  /// Cumulative time spent waiting for a connection, in milliseconds.
  wait_duration_ms : Int64
  /// Connections closed because the idle queue was full (`max_idle`).
  max_idle_closed : Int64
  /// Connections closed because they exceeded `max_idle_time`.
  max_idle_time_closed : Int64
  /// Connections closed because they exceeded `max_lifetime`.
  max_lifetime_closed : Int64
} derive(Eq, Debug)

///|
pub extend DBStats with Eq::{equal, not_equal}

///|
pub extend DBStats with Debug::{to_repr}

///|
/// Conversion from a MoonBit value into a SQL parameter `Value`.
pub(open) trait ToSql {
  fn to_sql(Self) -> Value
}

///|
/// Conversion from a driver `Value` into a typed MoonBit value.
pub(open) trait FromSql {
  fn from_sql(Value) -> Self raise
}
