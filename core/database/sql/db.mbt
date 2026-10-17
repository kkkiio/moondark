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
pub fn DB::DB(
  connector : &@driver.Connector,
  max_idle~ : Int32 = 5,
  max_open~ : Int32 = 10,
) -> DB {
  { pool: Pool::Pool(connector, max_idle~, max_open~), }
}

///|
/// Close the database connection pool.
pub async fn DB::close(self : DB) -> Unit {
  self.pool.close()
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
async fn acquire_retry(pool : Pool, attempt : Int32) -> Conn? {
  let result : Result[Conn, Error] = Ok(pool.acquire()) catch { e => Err(e) }
  match result {
    Ok(conn) => Some(conn)
    Err(e) =>
      if e is @driver.BadConn(_) && attempt < max_bad_conn_retries {
        None
      } else {
        raise e
      }
  }
}

///|
/// Release `conn` after a failed operation, discarding it when `e` is
/// `BadConn`. Returns `true` when the error is a `BadConn` and attempts
/// remain, i.e. the operation may be retried on a fresh connection.
async fn release_failed(
  pool : Pool,
  conn : Conn,
  e : Error,
  attempt : Int32,
) -> Bool {
  let bad = e is @driver.BadConn(_)
  pool.release(conn, bad~)
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
    let conn = match acquire_retry(self.pool, attempt) {
      Some(conn) => conn
      None => continue
    }
    // Capture errors so the statement and connection can be released
    // before the error propagates.
    let result : Result[(&@driver.Stmt, &@driver.Rows), Error] = Ok(
      {
        let stmt = conn.conn.prepare(query)
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
        return Rows::{ conn, stmt, rows, pool: Some(self.pool), closed: false, }
      Err(e) =>
        if release_failed(self.pool, conn, e, attempt) {
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
    let conn = match acquire_retry(self.pool, attempt) {
      Some(conn) => conn
      None => continue
    }
    // Capture errors so the statement and connection can be released
    // before the error propagates.
    let result : Result[ExecResult, Error] = Ok(
      {
        let stmt = conn.conn.prepare(query)
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
        self.pool.release(conn)
        return result
      }
      Err(e) =>
        if release_failed(self.pool, conn, e, attempt) {
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
    let conn = match acquire_retry(self.pool, attempt) {
      Some(conn) => conn
      None => continue
    }
    let result : Result[Unit, Error] = Ok(conn.conn.ping()) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => {
        self.pool.release(conn)
        return
      }
      Err(e) =>
        if release_failed(self.pool, conn, e, attempt) {
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
    let conn = match acquire_retry(self.pool, attempt) {
      Some(conn) => conn
      None => continue
    }
    let tx_result : Result[&@driver.Tx, Error] = Ok(conn.conn.begin()) catch {
      e => Err(e)
    }
    let tx = match tx_result {
      Ok(tx) => tx
      Err(e) =>
        if release_failed(self.pool, conn, e, attempt) {
          continue
        } else {
          raise e
        }
    }
    // The transaction has begun; do not retry past this point.
    let f_result : Result[T, Error] = Ok(f(Transaction::{ conn, tx, })) catch {
      e => Err(e)
    }
    let result = match f_result {
      Err(e) => {
        // Best-effort rollback; the error from `f` is the one reported.
        tx.rollback() catch {
          _ => ()
        }
        self.pool.release(conn, bad=e is @driver.BadConn(_))
        raise e
      }
      Ok(result) => result
    }
    let commit_result : Result[Unit, Error] = Ok(tx.commit()) catch {
      e => Err(e)
    }
    match commit_result {
      Err(e) => {
        self.pool.release(conn, bad=e is @driver.BadConn(_))
        raise e
      }
      Ok(_) => {
        self.pool.release(conn)
        return result
      }
    }
  }
  panic() // the last attempt either returns or raises
}

///|
struct Rows {
  conn : Conn
  stmt : &@driver.Stmt
  rows : &@driver.Rows
  pool : Pool?
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
      self.stmt.close() catch {
        _ => ()
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
  self.stmt.close()
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
  conn : Conn
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
  { conn: self.conn, stmt, rows, pool: None, closed: false, }
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
pub struct Conn {
  conn : &@driver.Conn
  /// Whether the connection was used before and returned to the pool.
  mut returned : Bool
}
