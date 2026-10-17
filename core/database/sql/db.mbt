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
pub async fn DB::query(
  self : Self,
  query : String,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> Rows {
  let conn = self.pool.acquire()
  errdefer self.pool.release(conn)
  let stmt = conn.conn.prepare(query)
  errdefer stmt.close()
  let rows = query_rows(stmt, params)
  { conn, stmt, rows, pool: Some(self.pool), closed: false, }
}

///|
pub async fn DB::execute(
  self : Self,
  query : String,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> ExecResult {
  let conn = self.pool.acquire()
  defer self.pool.release(conn)
  let stmt = conn.conn.prepare(query)
  defer stmt.close()
  exec_stmt(stmt, params)
}

///|
/// Verify a connection to the database is still alive, establishing one
/// if necessary. Connections failing `ping` with `BadConn` are discarded.
pub async fn DB::ping(self : Self) -> Unit {
  let conn = self.pool.acquire()
  let result : Result[Unit, Error] = Ok(conn.conn.ping()) catch { e => Err(e) }
  match result {
    Err(e) => {
      self.pool.release(conn, bad=e is @driver.BadConn(_))
      raise e
    }
    Ok(_) => self.pool.release(conn)
  }
}

///|
/// Execute a transaction and commit it if no error occurs.
pub async fn[T] DB::with_transaction(
  self : Self,
  f : async (Transaction) -> T,
) -> T {
  let conn = self.pool.acquire()
  defer self.pool.release(conn)
  let tx = conn.conn.begin()
  errdefer tx.rollback()
  let result = f(Transaction::{ conn, tx, })
  tx.commit()
  result
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
  if self.rows.next(values) {
    Some(Row::{ columns, values, })
  } else {
    self.close()
    None
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
