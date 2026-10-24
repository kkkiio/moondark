///|
struct RowStream {
  state : ClientState
  scope : Scope
  rows : &@driver.Rows
  names : Array[String]
  mut closed : Bool
  gate : @async.Mutex
}

///|
async fn[T] stream_scope(
  state : ClientState,
  stmt : &@driver.Stmt,
  params : ArrayView[&ToSql],
  f : async (RowStream) -> T,
) -> T {
  let args = bind(stmt, params)
  let rows = @async.protect_from_cancel(() => stmt.query(args[:]))
  state.retry_safe = false
  let scope = Scope::{ active: true, }
  let stream = RowStream::{
    state,
    scope,
    rows,
    names: rows.columns().to_owned(),
    closed: false,
    gate: @async.Mutex(),
  }
  state.active_stream = Some(stream)
  scoped(
    scope,
    () => {
      defer {
        state.active_stream = None
      }
      stream.close_rows()
    },
    () => f(stream),
  )
}

///|
fn RowStream::check(self : RowStream) -> Unit raise {
  self.scope.check()
  self.state.scope.check()
  if self.state.completed {
    raise DatabaseError::Closed("transaction")
  }
}

///|
/// Column names of the result set in positional order.
pub fn RowStream::columns(self : RowStream) -> ArrayView[String] raise {
  self.check()
  self.names[:]
}

///|
/// Explicitly drain any unread rows and close the stream before the callback ends.
pub async fn RowStream::finish(self : RowStream) -> Unit {
  self.check()
  self.close_rows()
}

///|
async fn RowStream::close_rows(self : RowStream) -> Unit {
  self.gate.acquire()
  defer self.gate.release()
  self.finish_inner()
}

///|
async fn RowStream::finish_inner(self : RowStream) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  errdefer {
    self.state.bad = true
  }
  @async.protect_from_cancel(() => self.rows.close())
}

///|
/// Advance the cursor and return the next `Row`, or `None` at EOF.
pub async fn RowStream::next(self : RowStream) -> Row? {
  self.check()
  check_pending_cancellation()
  self.gate.acquire()
  defer self.gate.release()
  self.check()
  if self.closed {
    return None
  }
  let values = Array::make(self.names.length(), Value::Null)
  errdefer @async.protect_from_cancel(() => {
    self.finish_inner() catch {
      _ => ()
    }
  })
  let more = @async.protect_from_cancel(() => self.rows.next(values))
  if more {
    Some(Row::{ names: self.names, data: values, })
  } else {
    self.finish_inner()
    None
  }
}

///|
/// Consume and return all remaining rows in the stream.
pub async fn RowStream::collect(self : RowStream) -> Array[Row] {
  self.check()
  let rows = []
  while self.next() is Some(row) {
    rows.push(row)
  }
  rows
}

///|
/// Consume the stream and return zero or one row, raising `DatabaseError::RowCount` if more than one row exists.
pub async fn RowStream::opt(self : RowStream) -> Row? {
  let first = self.next()
  if self.next() is Some(_) {
    raise DatabaseError::RowCount("expected at most one row")
  }
  first
}

///|
/// Consume the stream and return its single row, raising `DatabaseError::RowCount` otherwise.
pub async fn RowStream::one(self : RowStream) -> Row {
  match self.opt() {
    Some(row) => row
    None => raise DatabaseError::RowCount("expected exactly one row")
  }
}
