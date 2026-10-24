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
/// Asynchronous SQL connection pool handle, paired with a `DBExecutor`.
declare pub type DB

///|
/// Background supervisor driving the pool's connection creation and teardown workers.
declare pub type DBExecutor

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
/// Create a connection pool and its background `DBExecutor`.
///
/// Spawn `executor.run()` on a task group that outlives the `DB`, then call `db.ready()`.
declare pub fn DB::create(
  connector : &@driver.Connector,
  max_idle? : Int32,
  max_open? : Int32,
  max_lifetime? : @time.Duration,
  max_idle_time? : @time.Duration,
  statement_cache_capacity? : Int32,
) -> (DB, DBExecutor)

///|
/// Run the pool's background workers until `DB::close` is called.
declare pub async fn DBExecutor::run(self : DBExecutor) -> Unit

///|
/// Wait until `DBExecutor::run` has started serving pool requests.
declare pub async fn DB::ready(self : DB) -> Unit

///|
/// Gracefully close the connection pool and all pooled physical connections.
declare pub async fn DB::close(self : DB) -> Unit

///|
/// Return a snapshot of the pool's current and cumulative statistics.
declare pub fn DB::stats(self : DB) -> DBStats

///|
/// Verify connectivity to the database, retrying on `BadConn`.
declare pub async fn DB::ping(self : DB) -> Unit

///|
/// Execute a statement on a pooled connection and return its `ExecResult`.
declare pub async fn DB::execute(
  self : DB,
  sql : String,
  params? : ArrayView[&ToSql],
) -> ExecResult

///|
/// Execute a parameterless multi-statement SQL script on a pooled connection.
declare pub async fn DB::batch_execute(self : DB, script : String) -> Unit

///|
/// Execute `sql` on a pooled connection, collect all rows, and release the connection.
declare pub async fn DB::query_all(
  self : DB,
  sql : String,
  params? : ArrayView[&ToSql],
) -> Array[Row]

///|
/// Execute `sql` on a pooled connection and return exactly one row.
/// Raises `DatabaseError::RowCount` if the query returns 0 or more than 1 row.
declare pub async fn DB::query_one(
  self : DB,
  sql : String,
  params? : ArrayView[&ToSql],
) -> Row

///|
/// Execute `sql` on a pooled connection and return zero or one row.
/// Raises `DatabaseError::RowCount` if the query returns more than 1 row.
declare pub async fn DB::query_opt(
  self : DB,
  sql : String,
  params? : ArrayView[&ToSql],
) -> Row?

///|
/// Stream rows from `sql` within `f`, draining and releasing the connection on exit.
declare pub async fn[T] DB::with_stream(
  self : DB,
  sql : String,
  params? : ArrayView[&ToSql],
  f : async (RowStream) -> T,
) -> T

///|
/// Borrow a dedicated `Conn` for the duration of `f` (session affinity),
/// resetting and returning it to the pool when `f` exits.
declare pub async fn[T] DB::with_conn(self : DB, f : async (Conn) -> T) -> T

///|
/// Run `f` inside a database transaction, committing on normal return and
/// rolling back under cancellation protection if `f` raises or is cancelled.
declare pub async fn[T] DB::with_transaction(
  self : DB,
  f : async (Transaction) -> T,
) -> T

///|
declare pub impl GenericClient for DB

///|
/// A callback-scoped dedicated connection borrowed from `DB::with_conn`.
/// Using the handle after its callback completes raises `DatabaseError::ScopeExpired`.
declare pub type Conn

///|
declare pub async fn Conn::ping(self : Conn) -> Unit

///|
declare pub async fn Conn::execute(
  self : Conn,
  sql : String,
  params? : ArrayView[&ToSql],
) -> ExecResult

///|
declare pub async fn Conn::batch_execute(self : Conn, script : String) -> Unit

///|
declare pub async fn Conn::query_all(
  self : Conn,
  sql : String,
  params? : ArrayView[&ToSql],
) -> Array[Row]

///|
declare pub async fn Conn::query_one(
  self : Conn,
  sql : String,
  params? : ArrayView[&ToSql],
) -> Row

///|
declare pub async fn Conn::query_opt(
  self : Conn,
  sql : String,
  params? : ArrayView[&ToSql],
) -> Row?

///|
declare pub async fn[T] Conn::with_stream(
  self : Conn,
  sql : String,
  params? : ArrayView[&ToSql],
  f : async (RowStream) -> T,
) -> T

///|
/// Prepare `sql` on this connection for repeated execution inside `f`.
declare pub async fn[T] Conn::with_prepared(
  self : Conn,
  sql : String,
  f : async (PreparedStatement) -> T,
) -> T

///|
declare pub async fn[T] Conn::with_transaction(
  self : Conn,
  f : async (Transaction) -> T,
) -> T

///|
declare pub impl GenericClient for Conn

///|
/// A callback-scoped database transaction started by `DB::with_transaction` or `Conn::with_transaction`.
declare pub type Transaction

///|
/// Explicitly commit the transaction early; prevents automatic completion when the callback exits.
declare pub async fn Transaction::commit(self : Transaction) -> Unit

///|
/// Explicitly roll back the transaction early; prevents automatic commit when the callback exits.
declare pub async fn Transaction::rollback(self : Transaction) -> Unit

///|
declare pub async fn Transaction::ping(self : Transaction) -> Unit

///|
declare pub async fn Transaction::execute(
  self : Transaction,
  sql : String,
  params? : ArrayView[&ToSql],
) -> ExecResult

///|
declare pub async fn Transaction::batch_execute(
  self : Transaction,
  script : String,
) -> Unit

///|
declare pub async fn Transaction::query_all(
  self : Transaction,
  sql : String,
  params? : ArrayView[&ToSql],
) -> Array[Row]

///|
declare pub async fn Transaction::query_one(
  self : Transaction,
  sql : String,
  params? : ArrayView[&ToSql],
) -> Row

///|
declare pub async fn Transaction::query_opt(
  self : Transaction,
  sql : String,
  params? : ArrayView[&ToSql],
) -> Row?

///|
declare pub async fn[T] Transaction::with_stream(
  self : Transaction,
  sql : String,
  params? : ArrayView[&ToSql],
  f : async (RowStream) -> T,
) -> T

///|
declare pub async fn[T] Transaction::with_prepared(
  self : Transaction,
  sql : String,
  f : async (PreparedStatement) -> T,
) -> T

///|
declare pub impl GenericClient for Transaction

///|
/// A callback-scoped prepared statement bound to a `Conn` or `Transaction`.
declare pub type PreparedStatement

///|
/// Number of input parameters expected by the statement, or `-1` if unknown.
declare pub fn PreparedStatement::num_input(self : PreparedStatement) -> Int32

///|
declare pub async fn PreparedStatement::execute(
  self : PreparedStatement,
  params? : ArrayView[&ToSql],
) -> ExecResult

///|
declare pub async fn PreparedStatement::query_all(
  self : PreparedStatement,
  params? : ArrayView[&ToSql],
) -> Array[Row]

///|
declare pub async fn PreparedStatement::query_one(
  self : PreparedStatement,
  params? : ArrayView[&ToSql],
) -> Row

///|
declare pub async fn PreparedStatement::query_opt(
  self : PreparedStatement,
  params? : ArrayView[&ToSql],
) -> Row?

///|
declare pub async fn[T] PreparedStatement::with_stream(
  self : PreparedStatement,
  params? : ArrayView[&ToSql],
  f : async (RowStream) -> T,
) -> T

///|
/// A callback-scoped streaming cursor over result rows.
/// Unread rows are drained automatically when the enclosing `with_stream` scope exits.
declare pub type RowStream

///|
/// Column names of the result set in positional order.
declare pub fn RowStream::columns(self : RowStream) -> ArrayView[String]

///|
/// Advance the cursor and return the next `Row`, or `None` at EOF.
declare pub async fn RowStream::next(self : RowStream) -> Row?

///|
/// Consume and return all remaining rows in the stream.
declare pub async fn RowStream::collect(self : RowStream) -> Array[Row]

///|
/// Consume the stream and return its single row, raising `DatabaseError::RowCount` otherwise.
declare pub async fn RowStream::one(self : RowStream) -> Row

///|
/// Consume the stream and return zero or one row, raising `DatabaseError::RowCount` if more than one row exists.
declare pub async fn RowStream::opt(self : RowStream) -> Row?

///|
/// Explicitly drain any unread rows and close the stream before the callback ends.
declare pub async fn RowStream::finish(self : RowStream) -> Unit

///|
/// A materialized result row providing typed decoding by column index or column name.
declare pub type Row

///|
/// Read-only view of the row's column names.
declare pub fn Row::columns(self : Row) -> ArrayView[String]

///|
/// Read-only view of the row's raw driver values.
declare pub fn Row::values(self : Row) -> ArrayView[Value]

///|
/// Number of columns in the row.
declare pub fn Row::len(self : Row) -> Int32

///|
/// Zero-based index of the first column named `name`, or `None` if absent.
declare pub fn Row::index_of(self : Row, name : String) -> Int32?

///|
/// Decode the column at `index` into `T` (use `T?` for nullable columns).
declare pub fn[T : FromSql] Row::get(self : Row, index : Int32) -> T raise

///|
/// Decode the column named `name` into `T`; raises `DatabaseError::ColumnNotFound` if `name` is absent.
declare pub fn[T : FromSql] Row::get_name(self : Row, name : String) -> T raise

///|
/// Decode the column at `index` into `T?`, returning `None` when the SQL value is `NULL`.
declare pub fn[T : FromSql] Row::try_get(self : Row, index : Int32) -> T? raise

///|
/// Decode the column named `name` into `T?`, returning `None` when the SQL value is `NULL`.
declare pub fn[T : FromSql] Row::try_get_name(
  self : Row,
  name : String,
) -> T? raise

///|
/// Conversion from a MoonBit value into a SQL parameter `Value`.
pub(open) trait ToSql {
  fn to_sql(Self) -> Value
}

///|
declare pub impl ToSql for Value

///|
declare pub impl ToSql for Bool

///|
declare pub impl ToSql for Int32

///|
declare pub impl ToSql for Int64

///|
declare pub impl ToSql for UInt32

///|
declare pub impl ToSql for UInt64

///|
declare pub impl ToSql for Float

///|
declare pub impl ToSql for Double

///|
declare pub impl ToSql for String

///|
declare pub impl ToSql for StringView

///|
declare pub impl ToSql for Bytes

///|
declare pub impl ToSql for BytesView

///|
declare pub impl ToSql for @time.ZonedDateTime

///|
declare pub impl ToSql for Json

///|
declare pub impl[T : ToSql] ToSql for T?

///|
/// Conversion from a driver `Value` into a typed MoonBit value.
pub(open) trait FromSql {
  fn from_sql(Value) -> Self raise
}

///|
declare pub impl FromSql for Value

///|
declare pub impl FromSql for Bool

///|
declare pub impl FromSql for Int32

///|
declare pub impl FromSql for Int64

///|
declare pub impl FromSql for UInt32

///|
declare pub impl FromSql for UInt64

///|
declare pub impl FromSql for Float

///|
declare pub impl FromSql for Double

///|
declare pub impl FromSql for String

///|
declare pub impl FromSql for Bytes

///|
declare pub impl FromSql for @time.ZonedDateTime

///|
declare pub impl FromSql for Json

///|
declare pub impl[T : FromSql] FromSql for T?
