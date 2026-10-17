///|
/// A transaction on a checked-out connection, normally created by
/// `DB::with_transaction` or `Conn::with_transaction`.
struct Transaction {
  conn : ConnEntry
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
