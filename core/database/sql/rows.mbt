///|
/// Result rows of a query, holding the connection until `close`.
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
pub struct Row {
  columns : ArrayView[String]
  values : ArrayView[@driver.Value]
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
