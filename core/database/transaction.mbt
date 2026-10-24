///|
struct Transaction {
  state : ClientState
  tx : &@driver.Tx
  mut completed : Bool
  finish_gate : @async.Mutex
}

///|
fn Transaction::check(self : Transaction) -> Unit raise {
  self.state.scope.check()
  if self.completed {
    raise DatabaseError::Closed("transaction")
  }
}

///|
/// Explicitly commit the transaction early; prevents automatic completion when the callback exits.
pub async fn Transaction::commit(self : Transaction) -> Unit {
  self.check()
  self.finish_gate.acquire()
  defer self.finish_gate.release()
  self.check()
  if self.state.active_stream is Some(stream) {
    @async.protect_from_cancel(() => stream.close_rows())
  }
  self.state.operation(() => {
    self.check()
    errdefer {
      self.state.bad = true
    }
    @async.protect_from_cancel(() => self.tx.commit())
    self.completed = true
    self.state.completed = true
  })
}

///|
/// Explicitly roll back the transaction early; prevents automatic commit when the callback exits.
pub async fn Transaction::rollback(self : Transaction) -> Unit {
  self.check()
  self.finish_gate.acquire()
  defer self.finish_gate.release()
  self.check()
  if self.state.active_stream is Some(stream) {
    @async.protect_from_cancel(() => stream.close_rows())
  }
  self.state.operation(() => {
    self.check()
    errdefer {
      self.state.bad = true
    }
    @async.protect_from_cancel(() => self.tx.rollback())
    self.completed = true
    self.state.completed = true
  })
}

///|
pub async fn[T] Transaction::with_stream(
  self : Transaction,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  self.check()
  self.state.with_stream(sql, params, f)
}

///|
pub async fn Transaction::execute(
  self : Transaction,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
) -> ExecResult {
  self.check()
  self.state.with_statement(sql, stmt => {
    let args = bind(stmt, params)
    let result = @async.protect_from_cancel(() => stmt.exec(args[:]))
    self.state.retry_safe = false
    result
  })
}

///|
pub async fn Transaction::ping(self : Transaction) -> Unit {
  self.check()
  self.state.operation(() => {
    @async.protect_from_cancel(() => self.state.entry.conn.ping())
  })
}

///|
pub async fn Transaction::batch_execute(
  self : Transaction,
  script : String,
) -> Unit {
  self.check()
  self.state.operation(() => {
    @async.protect_from_cancel(() => self.state.entry.conn.batch_execute(script))
    self.state.retry_safe = false
  })
}

///|
pub async fn[T] Transaction::with_prepared(
  self : Transaction,
  sql : String,
  f : async (PreparedStatement) -> T,
) -> T {
  self.check()
  Conn::{ state: self.state, }.with_prepared(sql, f)
}

///|
pub async fn Transaction::query_all(
  self : Transaction,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
) -> Array[Row] {
  self.with_stream(sql, params~, stream => stream.collect())
}

///|
pub async fn Transaction::query_one(
  self : Transaction,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
) -> Row {
  self.with_stream(sql, params~, stream => stream.one())
}

///|
pub async fn Transaction::query_opt(
  self : Transaction,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
) -> Row? {
  self.with_stream(sql, params~, stream => stream.opt())
}

///|
pub impl GenericClient for Transaction with fn query_all(self, sql, params?) {
  self.query_all(sql, params?)
}

///|
pub impl GenericClient for Transaction with fn query_one(self, sql, params?) {
  self.query_one(sql, params?)
}

///|
pub impl GenericClient for Transaction with fn query_opt(self, sql, params?) {
  self.query_opt(sql, params?)
}

///|
pub impl GenericClient for Transaction with fn execute(self, sql, params?) {
  self.execute(sql, params?)
}

///|
pub impl GenericClient for Transaction with fn ping(self) {
  self.ping()
}

///|
pub impl GenericClient for Transaction with fn batch_execute(self, sql) {
  self.batch_execute(sql)
}
