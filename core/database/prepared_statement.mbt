///|
struct PreparedStatement {
  state : ClientState
  scope : Scope
  stmt : &@driver.Stmt
}

///|
/// Number of input parameters expected by the statement, or `-1` if unknown.
pub fn PreparedStatement::num_input(self : PreparedStatement) -> Int32 raise {
  self.scope.check()
  self.state.scope.check()
  if self.state.completed {
    raise DatabaseError::Closed("transaction")
  }
  self.stmt.num_input()
}

///|
pub async fn PreparedStatement::execute(
  self : PreparedStatement,
  params~ : ArrayView[&ToSql] = [],
) -> ExecResult {
  self.scope.check()
  self.state.operation(() => {
    self.scope.check()
    let args = bind(self.stmt, params)
    let result = @async.protect_from_cancel(() => self.stmt.exec(args[:]))
    self.state.retry_safe = false
    result
  })
}

///|
pub async fn[T] PreparedStatement::with_stream(
  self : PreparedStatement,
  params~ : ArrayView[&ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  self.scope.check()
  self.state.operation_with_permit(permit => {
    self.scope.check()
    let statement = StreamStatement::{
      state: self.state,
      stmt: self.stmt,
      close_on_finish: false,
      closed: false,
    }
    stream_scope(self.state, statement, params, permit, f)
  })
}

///|
pub async fn PreparedStatement::query_all(
  self : PreparedStatement,
  params~ : ArrayView[&ToSql] = [],
) -> Array[Row] {
  self.with_stream(params~, stream => stream.collect())
}

///|
pub async fn PreparedStatement::query_one(
  self : PreparedStatement,
  params~ : ArrayView[&ToSql] = [],
) -> Row {
  self.with_stream(params~, stream => stream.one())
}

///|
pub async fn PreparedStatement::query_opt(
  self : PreparedStatement,
  params~ : ArrayView[&ToSql] = [],
) -> Row? {
  self.with_stream(params~, stream => stream.opt())
}
