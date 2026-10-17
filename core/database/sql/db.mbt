///|
/// Database with connection pool
struct DB {
  pool : Pool
}

///|
pub type ExecResult = @driver.ExecResult

///|
pub type Value = @driver.Value

///|
/// Snapshot of connection pool statistics, mirroring `sql.DBStats` in Go.
pub struct DBStats {
  /// Maximum number of open connections (`max_open`).
  max_open : Int32
  /// Total connections managed by the pool (in_use + idle).
  open : Int32
  /// Connections currently checked out.
  in_use : Int32
  /// Connections idle in the pool (open - in_use).
  idle : Int32
  /// Total number of times a caller had to block waiting for a connection.
  wait_count : Int64
  /// Cumulative time blocked waiting for a connection, in milliseconds.
  wait_duration_ms : Int64
  /// Connections closed because the idle queue was full (max_idle).
  max_idle_closed : Int64
  /// Connections closed because they exceeded max_idle_time.
  max_idle_time_closed : Int64
  /// Connections closed because they exceeded max_lifetime.
  max_lifetime_closed : Int64
} derive(Debug)

///|
pub extend DBStats with Debug::{to_repr}

///|
/// `max_lifetime` bounds how long a connection may live: connections
/// older than it are closed instead of being reused or returned to the
/// pool. `max_idle_time` bounds how long a connection may sit idle in
/// the pool. `Duration::zero()` (the default) disables each limit.
/// Expiry is lazy: expired connections are discarded when encountered
/// while acquiring from or releasing to the pool; there is no
/// background reaper.
///
/// `max_stmts_per_conn` bounds the number of prepared statements cached
/// on each pooled connection (see `DB::prepare`); `0` (the default)
/// disables the limit, matching Go.
pub fn DB::DB(
  connector : &@driver.Connector,
  max_idle~ : Int32 = 5,
  max_open~ : Int32 = 10,
  max_lifetime~ : @time.Duration = @time.Duration::zero(),
  max_idle_time~ : @time.Duration = @time.Duration::zero(),
  max_stmts_per_conn~ : Int32 = 0,
) -> DB {
  {
    pool: Pool::Pool(
      connector,
      max_idle~,
      max_open~,
      max_lifetime~,
      max_idle_time~,
      max_stmts_per_conn~,
    ),
  }
}

///|
/// Close the database connection pool.
pub async fn DB::close(self : DB) -> Unit {
  self.pool.close()
}

///|
/// Check out a dedicated connection from the pool, mirroring
/// `sql.DB.Conn` in Go. The returned `Conn` is not shared until
/// `Conn::close` returns it to the pool.
pub async fn DB::conn(self : Self) -> Conn {
  Conn::{ pool: self.pool, entry: Some(self.pool.acquire()), closed: false, }
}

///|
/// Create a prepared statement that runs on pooled connections. Like
/// `sql.Stmt` in Go, the physical driver statement is cached per
/// connection and re-prepared lazily on each new connection; the
/// per-connection cache is bounded by `max_stmts_per_conn`.
pub fn DB::prepare(self : Self, query : String) -> Stmt {
  Stmt::{ query, pool: self.pool, bound: None, closed: false, handles: {}, }
}

///|
/// Return a snapshot of the connection pool's statistics. Counters like
/// `wait_count` are cumulative since the `DB` was created; gauges like
/// `open`, `in_use` and `idle` reflect the current state.
pub fn DB::stats(self : DB) -> DBStats {
  {
    max_open: self.pool.max_open,
    open: self.pool.active_count,
    in_use: self.pool.in_use,
    idle: self.pool.active_count - self.pool.in_use,
    wait_count: self.pool.wait_count,
    wait_duration_ms: self.pool.wait_duration_ms,
    max_idle_closed: self.pool.max_idle_closed,
    max_idle_time_closed: self.pool.max_idle_time_closed,
    max_lifetime_closed: self.pool.max_lifetime_closed,
  }
}

///|
/// Maximum number of times an operation is retried after its connection
/// raises `BadConn` (2 retries, 3 attempts total, as in Go). Retrying is
/// only safe because `BadConn` guarantees the operation was never sent
/// to the server.
let max_bad_conn_retries : Int32 = 2

///|
/// Acquire a connection for attempt `attempt` of a retried operation.
/// Returns `None` when acquisition fails with `BadConn` and attempts
/// remain, signaling the caller to retry; any other error is raised.
async fn acquire_retry(pool : Pool, attempt : Int32) -> ConnEntry? {
  let result : Result[ConnEntry, Error] = Ok(pool.acquire()) catch {
    e => Err(e)
  }
  match result {
    Ok(entry) => Some(entry)
    Err(e) =>
      if e is @driver.BadConn(_) && attempt < max_bad_conn_retries {
        None
      } else {
        raise e
      }
  }
}

///|
/// Release `entry` after a failed operation, discarding it when `e` is
/// `BadConn`. Returns `true` when the error is a `BadConn` and attempts
/// remain, i.e. the operation may be retried on a fresh connection.
async fn release_failed(
  pool : Pool,
  entry : ConnEntry,
  e : Error,
  attempt : Int32,
) -> Bool {
  let bad = e is @driver.BadConn(_)
  pool.release(entry, bad~)
  bad && attempt < max_bad_conn_retries
}

///|
fn values_of(params : ArrayView[&@driver.Valuer]) -> Array[@driver.Value] {
  params.map(fn(param) { param.to_value() })
}

///|
/// Check the number of parameters against the prepared statement.
/// `num_input` may return a negative value to skip the check.
fn check_num_input(
  stmt : &@driver.Stmt,
  params : ArrayView[&@driver.Valuer],
) -> Unit raise {
  let expected = stmt.num_input()
  if expected >= 0 && expected != params.length() {
    fail("expected \{expected} parameters, got \{params.length()}")
  }
}

///|
async fn query_rows(
  stmt : &@driver.Stmt,
  params : ArrayView[&@driver.Valuer],
) -> &@driver.Rows {
  check_num_input(stmt, params)
  stmt.query(values_of(params))
}

///|
async fn exec_stmt(
  stmt : &@driver.Stmt,
  params : ArrayView[&@driver.Valuer],
) -> ExecResult {
  check_num_input(stmt, params)
  stmt.exec(values_of(params))
}

///|
/// Run `query` and return its result rows; the connection stays checked
/// out until `Rows::close` returns it to the pool. Failures with
/// `BadConn` are retried on a fresh connection.
pub async fn DB::query(
  self : Self,
  query : String,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> Rows {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match acquire_retry(self.pool, attempt) {
      Some(entry) => entry
      None => continue
    }
    // Capture errors so the statement and connection can be released
    // before the error propagates.
    let result : Result[(&@driver.Stmt, &@driver.Rows), Error] = Ok(
      {
        let stmt = entry.conn.prepare(query)
        let queried : Result[&@driver.Rows, Error] = Ok(
          query_rows(stmt, params),
        ) catch {
          e => Err(e)
        }
        match queried {
          Ok(rows) => (stmt, rows)
          // Close the statement even on failure so driver resources are
          // not leaked; the original error is the one that propagates.
          Err(e) => {
            stmt.close() catch {
              _ => ()
            }
            raise e
          }
        }
      },
    ) catch {
      e => Err(e)
    }
    match result {
      Ok((stmt, rows)) =>
        // Success: the connection is released later by `Rows::close`.
        return Rows::{
          conn: entry,
          stmt,
          rows,
          pool: Some(self.pool),
          close_stmt: true,
          closed: false,
        }
      Err(e) =>
        if release_failed(self.pool, entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
  }
  panic() // the last attempt either returns or raises
}

///|
/// Execute a statement and return its result. Failures with `BadConn`
/// are retried on a fresh connection.
pub async fn DB::execute(
  self : Self,
  query : String,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> ExecResult {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match acquire_retry(self.pool, attempt) {
      Some(entry) => entry
      None => continue
    }
    // Capture errors so the statement and connection can be released
    // before the error propagates.
    let result : Result[ExecResult, Error] = Ok(
      {
        let stmt = entry.conn.prepare(query)
        let executed : Result[ExecResult, Error] = Ok(exec_stmt(stmt, params)) catch {
          e => Err(e)
        }
        match executed {
          // Close the statement even on failure so driver resources are
          // not leaked; the original error is the one that propagates.
          Err(e) => {
            stmt.close() catch {
              _ => ()
            }
            raise e
          }
          Ok(result) => {
            stmt.close()
            result
          }
        }
      },
    ) catch {
      e => Err(e)
    }
    match result {
      Ok(result) => {
        self.pool.release(entry)
        return result
      }
      Err(e) =>
        if release_failed(self.pool, entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
  }
  panic() // the last attempt either returns or raises
}

///|
/// Verify a connection to the database is still alive, establishing one
/// if necessary. Connections failing `ping` with `BadConn` are discarded
/// and the ping is retried on a fresh connection.
pub async fn DB::ping(self : Self) -> Unit {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match acquire_retry(self.pool, attempt) {
      Some(entry) => entry
      None => continue
    }
    let result : Result[Unit, Error] = Ok(entry.conn.ping()) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => {
        self.pool.release(entry)
        return
      }
      Err(e) =>
        if release_failed(self.pool, entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
  }
}

///|
/// Execute a transaction and commit it if no error occurs. Acquiring a
/// connection and beginning the transaction are retried on `BadConn`;
/// once `f` runs the transaction may have produced side effects, so
/// errors from `f` or `commit` are never retried.
pub async fn[T] DB::with_transaction(
  self : Self,
  f : async (Transaction) -> T,
) -> T {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match acquire_retry(self.pool, attempt) {
      Some(entry) => entry
      None => continue
    }
    let tx_result : Result[&@driver.Tx, Error] = Ok(entry.conn.begin()) catch {
      e => Err(e)
    }
    let tx = match tx_result {
      Ok(tx) => tx
      Err(e) =>
        if release_failed(self.pool, entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
    // The transaction has begun; do not retry past this point.
    let f_result : Result[T, Error] = Ok(f(Transaction::{ conn: entry, tx, })) catch {
      e => Err(e)
    }
    let result = match f_result {
      Err(e) => {
        // Best-effort rollback; the error from `f` is the one reported.
        tx.rollback() catch {
          _ => ()
        }
        self.pool.release(entry, bad=e is @driver.BadConn(_))
        raise e
      }
      Ok(result) => result
    }
    let commit_result : Result[Unit, Error] = Ok(tx.commit()) catch {
      e => Err(e)
    }
    match commit_result {
      Err(e) => {
        self.pool.release(entry, bad=e is @driver.BadConn(_))
        raise e
      }
      Ok(_) => {
        self.pool.release(entry)
        return result
      }
    }
  }
  panic() // the last attempt either returns or raises
}

///|
/// A dedicated connection checked out of the pool. Like `sql.Conn` in
/// Go, it is not shared until `close` returns it to the pool. If the
/// underlying connection dies (`BadConn`), the next operation acquires
/// a fresh one automatically.
pub struct Conn {
  priv pool : Pool
  priv mut entry : ConnEntry?
  priv mut closed : Bool
}

///|
/// Return the checked-out entry, acquiring a fresh connection when the
/// previous one was discarded as `BadConn`. Returns `None` when
/// acquisition fails with `BadConn` and attempts remain, signaling the
/// caller to retry; any other error is raised.
async fn Conn::acquire_entry(self : Conn, attempt : Int32) -> ConnEntry? {
  if self.closed {
    fail("use of closed connection")
  }
  match self.entry {
    Some(entry) => Some(entry)
    None => {
      let result : Result[ConnEntry, Error] = Ok(self.pool.acquire()) catch {
        e => Err(e)
      }
      match result {
        Ok(entry) => {
          self.entry = Some(entry)
          Some(entry)
        }
        Err(e) =>
          if e is @driver.BadConn(_) && attempt < max_bad_conn_retries {
            None
          } else {
            raise e
          }
      }
    }
  }
}

///|
/// Discard `entry` when `e` is `BadConn`, so the next attempt (or the
/// next operation on this `Conn`) acquires a fresh connection. Returns
/// `true` when the operation may be retried.
async fn Conn::fail_entry(
  self : Conn,
  entry : ConnEntry,
  e : Error,
  attempt : Int32,
) -> Bool {
  if e is @driver.BadConn(_) {
    self.pool.release(entry, bad=true)
    self.entry = None
    attempt < max_bad_conn_retries
  } else {
    false
  }
}

///|
/// Return the connection to the pool. Subsequent calls are no-ops and
/// subsequent operations raise `use of closed connection`.
pub async fn Conn::close(self : Self) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if self.entry is Some(entry) {
    self.entry = None
    self.pool.release(entry)
  }
}

///|
/// Verify the checked-out connection is still alive, acquiring a fresh
/// one if the previous connection was discarded. Failures with
/// `BadConn` are retried on a fresh connection.
pub async fn Conn::ping(self : Self) -> Unit {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match self.acquire_entry(attempt) {
      Some(entry) => entry
      None => continue
    }
    let result : Result[Unit, Error] = Ok(entry.conn.ping()) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => return
      Err(e) =>
        if self.fail_entry(entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
  }
}

///|
/// Run `query` on the dedicated connection and return its result rows.
/// The connection stays checked out: `Rows::close` closes the result
/// but does not return the connection to the pool. Failures with
/// `BadConn` are retried on a fresh connection.
pub async fn Conn::query(
  self : Self,
  query : String,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> Rows {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match self.acquire_entry(attempt) {
      Some(entry) => entry
      None => continue
    }
    // Capture errors so the statement can be closed before the error
    // propagates.
    let result : Result[(&@driver.Stmt, &@driver.Rows), Error] = Ok(
      {
        let stmt = entry.conn.prepare(query)
        let queried : Result[&@driver.Rows, Error] = Ok(
          query_rows(stmt, params),
        ) catch {
          e => Err(e)
        }
        match queried {
          Ok(rows) => (stmt, rows)
          Err(e) => {
            stmt.close() catch {
              _ => ()
            }
            raise e
          }
        }
      },
    ) catch {
      e => Err(e)
    }
    match result {
      Ok((stmt, rows)) =>
        return Rows::{
          conn: entry,
          stmt,
          rows,
          pool: None,
          close_stmt: true,
          closed: false,
        }
      Err(e) =>
        if self.fail_entry(entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
  }
  panic() // the last attempt either returns or raises
}

///|
/// Execute a statement on the dedicated connection and return its
/// result. Failures with `BadConn` discard the connection and are
/// retried on a fresh one.
pub async fn Conn::execute(
  self : Self,
  query : String,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> ExecResult {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match self.acquire_entry(attempt) {
      Some(entry) => entry
      None => continue
    }
    // Capture errors so the statement can be closed before the error
    // propagates.
    let result : Result[ExecResult, Error] = Ok(
      {
        let stmt = entry.conn.prepare(query)
        let executed : Result[ExecResult, Error] = Ok(exec_stmt(stmt, params)) catch {
          e => Err(e)
        }
        match executed {
          Err(e) => {
            stmt.close() catch {
              _ => ()
            }
            raise e
          }
          Ok(result) => {
            stmt.close()
            result
          }
        }
      },
    ) catch {
      e => Err(e)
    }
    match result {
      Ok(result) => return result
      Err(e) =>
        if self.fail_entry(entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
  }
  panic() // the last attempt either returns or raises
}

///|
/// Execute a transaction on the dedicated connection and commit it if
/// no error occurs. Beginning the transaction is retried on `BadConn`;
/// once `f` runs the transaction may have produced side effects, so
/// errors from `f` or `commit` are never retried. The connection stays
/// checked out afterwards unless it died with `BadConn`.
pub async fn[T] Conn::with_transaction(
  self : Self,
  f : async (Transaction) -> T,
) -> T {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match self.acquire_entry(attempt) {
      Some(entry) => entry
      None => continue
    }
    let tx_result : Result[&@driver.Tx, Error] = Ok(entry.conn.begin()) catch {
      e => Err(e)
    }
    let tx = match tx_result {
      Ok(tx) => tx
      Err(e) =>
        if self.fail_entry(entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
    // The transaction has begun; do not retry past this point.
    let f_result : Result[T, Error] = Ok(f(Transaction::{ conn: entry, tx, })) catch {
      e => Err(e)
    }
    let result = match f_result {
      Err(e) => {
        // Best-effort rollback; the error from `f` is the one reported.
        tx.rollback() catch {
          _ => ()
        }
        if e is @driver.BadConn(_) {
          self.pool.release(entry, bad=true)
          self.entry = None
        }
        raise e
      }
      Ok(result) => result
    }
    let commit_result : Result[Unit, Error] = Ok(tx.commit()) catch {
      e => Err(e)
    }
    match commit_result {
      Err(e) => {
        if e is @driver.BadConn(_) {
          self.pool.release(entry, bad=true)
          self.entry = None
        }
        raise e
      }
      Ok(_) => return result
    }
  }
  panic() // the last attempt either returns or raises
}

///|
/// Create a prepared statement bound to this connection. The statement
/// always runs on this dedicated connection; if the underlying
/// connection dies (`BadConn`), a fresh one is acquired lazily and the
/// statement re-prepared on it.
pub fn Conn::prepare(self : Self, query : String) -> Stmt raise {
  if self.closed {
    fail("use of closed connection")
  }
  Stmt::{
    query,
    pool: self.pool,
    bound: Some(self),
    closed: false,
    handles: {},
  }
}

///|
/// A prepared statement. Like `sql.Stmt` in Go, it can be reused
/// concurrently; a physical prepared statement is cached per pooled
/// connection and re-prepared lazily on each new connection.
pub struct Stmt {
  query : String
  /// The pool unbound statements acquire connections from.
  priv pool : Pool
  /// Bound to a specific connection when created via `Conn::prepare`;
  /// unbound statements (via `DB::prepare`) run on any pooled conn.
  priv bound : Conn?
  priv mut closed : Bool
  /// conn entry id -> live prepared driver statement
  priv handles : Map[Int64, ConnStmt]
}

///|
/// A driver statement prepared on a specific pooled connection,
/// cross-referenced by the `Stmt` that owns it so both cache eviction
/// and `Stmt::close` can find and close it.
priv struct ConnStmt {
  entry : ConnEntry
  stmt : &@driver.Stmt
  owner : Stmt
}

///|
/// The entry a bound statement runs on: the bound conn's checked-out
/// entry, acquiring a fresh connection if the previous one died.
async fn Stmt::bound_entry(self : Stmt) -> ConnEntry {
  guard self.bound is Some(conn) else { panic() }
  if conn.closed {
    fail("use of closed connection")
  }
  match conn.entry {
    Some(entry) => entry
    None => {
      let entry = conn.pool.acquire()
      conn.entry = Some(entry)
      entry
    }
  }
}

///|
/// Return the driver statement for `self` prepared on `entry',
/// preparing and caching it on a cache miss. The per-connection cache
/// is LRU: hits move the entry to newest (re-inserted at the end), and
/// inserts evict the oldest (first-iterated) statement once
/// `max_stmts_per_conn` is exceeded.
async fn Stmt::cached_on(self : Stmt, entry : ConnEntry) -> ConnStmt {
  match entry.stmt_cache.get(self.query) {
    Some(cs) => {
      // Bump LRU order: removing and re-setting moves the entry to
      // newest in the insertion-ordered map.
      entry.stmt_cache.remove(self.query)
      entry.stmt_cache[self.query] = cs
      cs
    }
    None => {
      let cs = ConnStmt::{
        entry,
        stmt: entry.conn.prepare(self.query),
        owner: self,
      }
      entry.stmt_cache[self.query] = cs
      self.handles[entry.id] = cs
      let max_stmts = self.pool.max_stmts_per_conn
      if max_stmts > 0 && entry.stmt_cache.length() > max_stmts {
        // Evict the least recently used statement: the first key in
        // insertion order.
        if entry.stmt_cache.iter().next() is Some((key, evicted)) {
          entry.stmt_cache.remove(key)
          evicted.owner.handles.remove(entry.id)
          evicted.stmt.close() catch {
            _ => ()
          }
        }
      }
      cs
    }
  }
}

///|
/// Execute the prepared statement with `params` and return its result.
/// Unbound statements retry `BadConn` failures on a fresh connection;
/// bound statements discard the dead connection and propagate the error.
pub async fn Stmt::execute(
  self : Self,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> ExecResult {
  if self.closed {
    fail("use of closed statement")
  }
  match self.bound {
    Some(conn) => {
      let entry = self.bound_entry()
      let executed : Result[ExecResult, Error] = Ok(
        exec_stmt(self.cached_on(entry).stmt, params),
      ) catch {
        e => Err(e)
      }
      match executed {
        Ok(result) => result
        Err(e) => {
          if e is @driver.BadConn(_) {
            self.pool.release(entry, bad=true)
            conn.entry = None
          }
          raise e
        }
      }
    }
    None => {
      for attempt in 0..<=max_bad_conn_retries {
        let entry = match acquire_retry(self.pool, attempt) {
          Some(entry) => entry
          None => continue
        }
        let executed : Result[ExecResult, Error] = Ok(
          exec_stmt(self.cached_on(entry).stmt, params),
        ) catch {
          e => Err(e)
        }
        match executed {
          Ok(result) => {
            self.pool.release(entry)
            return result
          }
          Err(e) =>
            if release_failed(self.pool, entry, e, attempt) {
              continue
            } else {
              raise e
            }
        }
      }
      panic() // the last attempt either returns or raises
    }
  }
}

///|
/// Run the prepared statement with `params` and return its result rows.
/// Unbound statements keep the connection checked out until
/// `Rows::close` returns it to the pool; the cached driver statement is
/// not closed with the rows.
pub async fn Stmt::query(
  self : Self,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> Rows {
  if self.closed {
    fail("use of closed statement")
  }
  match self.bound {
    Some(conn) => {
      let entry = self.bound_entry()
      let queried : Result[(&@driver.Stmt, &@driver.Rows), Error] = Ok(
        {
          let cs = self.cached_on(entry)
          (cs.stmt, query_rows(cs.stmt, params))
        },
      ) catch {
        e => Err(e)
      }
      match queried {
        Ok((stmt, rows)) =>
          Rows::{
            conn: entry,
            stmt,
            rows,
            pool: None,
            close_stmt: false,
            closed: false,
          }
        Err(e) => {
          if e is @driver.BadConn(_) {
            self.pool.release(entry, bad=true)
            conn.entry = None
          }
          raise e
        }
      }
    }
    None => {
      for attempt in 0..<=max_bad_conn_retries {
        let entry = match acquire_retry(self.pool, attempt) {
          Some(entry) => entry
          None => continue
        }
        let queried : Result[(&@driver.Stmt, &@driver.Rows), Error] = Ok(
          {
            let cs = self.cached_on(entry)
            (cs.stmt, query_rows(cs.stmt, params))
          },
        ) catch {
          e => Err(e)
        }
        match queried {
          Ok((stmt, rows)) =>
            // Success: the connection is released later by
            // `Rows::close`; the cached statement stays open.
            return Rows::{
              conn: entry,
              stmt,
              rows,
              pool: Some(self.pool),
              close_stmt: false,
              closed: false,
            }
          Err(e) =>
            if release_failed(self.pool, entry, e, attempt) {
              continue
            } else {
              raise e
            }
        }
      }
      panic() // the last attempt either returns or raises
    }
  }
}

///|
/// Close the statement and every driver statement cached for it, on
/// every pooled connection it was prepared on. Idempotent; executing or
/// querying a closed statement raises `use of closed statement`.
pub async fn Stmt::close(self : Self) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for _, cs in self.handles {
    cs.stmt.close() catch {
      _ => ()
    }
    cs.entry.stmt_cache.remove(self.query)
  }
  self.handles.clear()
}

///|
struct Rows {
  conn : ConnEntry
  stmt : &@driver.Stmt
  rows : &@driver.Rows
  pool : Pool?
  /// Whether `stmt` is a one-shot statement closed with the rows;
  /// `false` when it belongs to a `Stmt`'s per-connection cache.
  close_stmt : Bool
  mut closed : Bool
}

///|
/// Fetch the next row, or `None` if the result is exhausted.
/// Exhausted results are closed automatically.
pub async fn Rows::next(self : Self) -> Row? {
  if self.closed {
    return None
  }
  let columns = self.rows.columns()
  let values = Array::make(columns.length(), @driver.Value::Null)
  let next : Result[Bool, Error] = Ok(self.rows.next(values)) catch {
    e => Err(e)
  }
  match next {
    Err(e) => {
      // A failed result set must not return its connection to the pool.
      self.rows.close() catch {
        _ => ()
      }
      if self.close_stmt {
        self.stmt.close() catch {
          _ => ()
        }
      }
      if self.pool is Some(pool) {
        pool.release(self.conn, bad=e is @driver.BadConn(_))
      }
      self.closed = true
      raise e
    }
    Ok(has_row) =>
      if has_row {
        Some(Row::{ columns, values, })
      } else {
        self.close()
        None
      }
  }
}

///|
/// Close the result and return the connection to the pool.
pub async fn Rows::close(self : Self) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.rows.close()
  if self.close_stmt {
    self.stmt.close()
  }
  if self.pool is Some(pool) {
    pool.release(self.conn)
  }
}

///|
struct Row {
  columns : Array[String]
  values : Array[@driver.Value]
} derive(Debug)

///|
pub extend Row with Debug::{to_repr}

///|
/// Get the value of the column with the given name.
pub fn Row::get(self : Self, name : String) -> Value? {
  for i, column in self.columns {
    if column == name {
      return Some(self.values[i])
    }
  }
  None
}

///|
struct Transaction {
  conn : ConnEntry
  tx : &@driver.Tx
}

///|
pub async fn Transaction::query(
  self : Self,
  query : String,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> Rows {
  let stmt = self.conn.conn.prepare(query)
  let rows = query_rows(stmt, params)
  { conn: self.conn, stmt, rows, pool: None, close_stmt: true, closed: false, }
}

///|
pub async fn Transaction::execute(
  self : Self,
  query : String,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> ExecResult {
  let stmt = self.conn.conn.prepare(query)
  defer stmt.close()
  exec_stmt(stmt, params)
}

///|
/// Commit the transaction. Normally called by `DB::with_transaction`.
pub async fn Transaction::commit(self : Self) -> Unit {
  self.tx.commit()
}

///|
/// Rollback the transaction. Normally called by `DB::with_transaction`.
pub async fn Transaction::rollback(self : Self) -> Unit {
  self.tx.rollback()
}

///|
/// A connection managed by the pool: the queue element wrapping a
/// driver connection with its identity, bookkeeping timestamps and
/// per-connection prepared statement cache.
priv struct ConnEntry {
  /// Unique id assigned by the pool; keys `Stmt::handles`.
  id : Int64
  conn : &@driver.Conn
  /// Whether the connection was used before and returned to the pool.
  mut returned : Bool
  /// When the driver connection was opened, in milliseconds.
  created_at : Int64
  /// When the connection was last returned to the pool, in
  /// milliseconds; `0` while it has never been returned.
  mut returned_at : Int64
  /// Cached prepared statements on this connection, keyed by query
  /// text; insertion order is the LRU order (oldest first).
  stmt_cache : Map[String, ConnStmt]
}

///|
/// Close the driver connection and every statement cached on it,
/// unregistering each from its owning `Stmt`.
async fn ConnEntry::close(self : ConnEntry) -> Unit {
  for _, cs in self.stmt_cache {
    cs.stmt.close() catch {
      _ => ()
    }
    cs.owner.handles.remove(self.id)
  }
  self.stmt_cache.clear()
  self.conn.close()
}
