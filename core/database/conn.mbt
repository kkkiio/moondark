///|
struct Conn {
  state : ClientState
}

///|
/// Prepare `sql` on this connection for repeated execution inside `f`.
pub async fn[T] Conn::with_prepared(
  self : Conn,
  sql : String,
  f : async (PreparedStatement) -> T,
) -> T {
  self.state.scope.check()
  let stmt = self.state.operation(() => {
    @async.protect_from_cancel(() => self.state.entry.conn.prepare(sql))
  })
  let scope = Scope::{ active: true, }
  scoped(
    scope,
    () => {
      self.state.gate.acquire()
      defer self.state.gate.release()
      errdefer {
        self.state.bad = true
      }
      stmt.close()
    },
    () => f(PreparedStatement::{ state: self.state, scope, stmt, }),
  )
}

///|
pub async fn[T] Conn::with_transaction(
  self : Conn,
  f : async (Transaction) -> T,
) -> T {
  self.state.operation(() => {
    let tx = @async.protect_from_cancel(() => self.state.entry.conn.begin())
    let scope = Scope::{ active: true, }
    let state = ClientState::{
      entry: self.state.entry,
      pool: self.state.pool,
      scope,
      gate: @async.Mutex(),
      bad: false,
      completed: false,
      retry_safe: true,
      active_stream: None,
    }
    let transaction = Transaction::{
      state,
      tx,
      completed: false,
      finish_gate: @async.Mutex(),
    }
    defer (if state.bad { self.state.bad = true })
    scoped(
      scope,
      () => {
        state.gate.acquire()
        defer state.gate.release()
        if !transaction.completed {
          errdefer {
            state.bad = true
          }
          transaction.tx.rollback()
          transaction.completed = true
        }
      },
      () => {
        let result = f(transaction)
        check_pending_cancellation()
        if !transaction.completed {
          transaction.commit()
        }
        result
      },
    )
  })
}

///|
pub async fn[T] Conn::with_stream(
  self : Conn,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  self.state.scope.check()
  self.state.with_stream(sql, params, f)
}

///|
pub async fn Conn::execute(
  self : Conn,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
) -> ExecResult {
  self.state.scope.check()
  self.state.with_statement(sql, stmt => {
    let args = bind(stmt, params)
    let result = @async.protect_from_cancel(() => stmt.exec(args[:]))
    self.state.retry_safe = false
    result
  })
}

///|
pub async fn Conn::ping(self : Conn) -> Unit {
  self.state.scope.check()
  self.state.operation(() => {
    @async.protect_from_cancel(() => self.state.entry.conn.ping())
  })
}

///|
pub async fn Conn::batch_execute(self : Conn, script : String) -> Unit {
  self.state.scope.check()
  self.state.operation(() => {
    @async.protect_from_cancel(() => self.state.entry.conn.batch_execute(script))
    self.state.retry_safe = false
  })
}

///|
pub async fn Conn::query_all(
  self : Conn,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
) -> Array[Row] {
  self.with_stream(sql, params~, stream => stream.collect())
}

///|
pub async fn Conn::query_one(
  self : Conn,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
) -> Row {
  self.with_stream(sql, params~, stream => stream.one())
}

///|
pub async fn Conn::query_opt(
  self : Conn,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
) -> Row? {
  self.with_stream(sql, params~, stream => stream.opt())
}

///|
pub impl GenericClient for Conn with fn query_all(self, sql, params?) {
  self.query_all(sql, params?)
}

///|
pub impl GenericClient for Conn with fn query_one(self, sql, params?) {
  self.query_one(sql, params?)
}

///|
pub impl GenericClient for Conn with fn query_opt(self, sql, params?) {
  self.query_opt(sql, params?)
}

///|
pub impl GenericClient for Conn with fn execute(self, sql, params?) {
  self.execute(sql, params?)
}

///|
pub impl GenericClient for Conn with fn ping(self) {
  self.ping()
}

///|
pub impl GenericClient for Conn with fn batch_execute(self, sql) {
  self.batch_execute(sql)
}
