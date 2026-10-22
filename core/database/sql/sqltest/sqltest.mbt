///|
/// A fake `driver.Connector` for tests and executable documentation:
/// `connect` returns an in-memory `FakeConn` that records every
/// executed statement and counts commits/rollbacks, but performs no
/// I/O. Queries always return an empty result set, so `begin`,
/// `commit` and `rollback` exercise the real `database/sql` pooling
/// and transaction plumbing while the "database" itself is a no-op.
///
/// Use it when the *shape* of `DB`/`Transaction` code matters — e.g.
/// APIs taking `@sql.Transaction` — and a real driver is unavailable
/// or unnecessary. It cannot demonstrate durability or visibility
/// semantics; test those against a real database.
pub struct FakeConnector {
  /// every connection this connector has produced, in order.
  conns : Array[FakeConn]
}

///|
/// An empty connector.
pub fn FakeConnector::new() -> FakeConnector {
  FakeConnector::{ conns: [], }
}

///|
/// Create a `DB` pool over this connector. The returned `DBExecutor`
/// must be spawned on a task group and `db.ready()` awaited, exactly
/// like a real driver.
pub fn FakeConnector::open_db(self : Self) -> (@sql.DB, @sql.DBExecutor) {
  @sql.DB::create(self)
}

///|
pub impl @driver.Connector for FakeConnector with fn connect(self) {
  let conn = FakeConn::{
    statements: [],
    closed: false,
    commit_count: 0,
    rollback_count: 0,
  }
  self.conns.push(conn)
  (conn, @driver.NoopExecutor::{ })
}

///|
/// A recorded fake connection. `statements` holds every `(sql,
/// params)` pair executed on it — inside or outside a transaction —
/// in execution order.
pub(all) struct FakeConn {
  statements : Array[(String, Array[@driver.Value])]
  mut closed : Bool
  mut commit_count : Int32
  mut rollback_count : Int32
}

///|
pub impl @driver.Conn for FakeConn with fn prepare(self, sql) {
  FakeStmt::{ conn: self, sql, }
}

///|
pub impl @driver.Conn for FakeConn with fn close(self) {
  self.closed = true
}

///|
pub impl @driver.Conn for FakeConn with fn begin(self) {
  FakeTx::{ conn: self, }
}

///|
pub impl @driver.Conn for FakeConn with fn execute_script(self, script) {
  self.statements.push((script, []))
}

///|
/// Prepared statement returned by `FakeConn::prepare`; executing or
/// querying it appends to `conn.statements`.
priv struct FakeStmt {
  conn : FakeConn
  sql : String
}

///|
impl @driver.Stmt for FakeStmt with fn exec(self, args) {
  self.conn.statements.push((self.sql, args))
  @driver.ExecResult::{ rows_affected: Some(1), last_insert_id: None, }
}

///|
impl @driver.Stmt for FakeStmt with fn query(self, args) {
  self.conn.statements.push((self.sql, args))
  FakeRows::{ }
}

///|
impl @driver.Stmt for FakeStmt with fn num_input(_self) {
  -1
}

///|
impl @driver.Stmt for FakeStmt with fn close(self) {
  ignore(self)
}

///|
/// Driver transaction returned by `FakeConn::begin`; commit and
/// rollback are counted on the connection, nothing else.
priv struct FakeTx {
  conn : FakeConn
}

///|
impl @driver.Tx for FakeTx with fn commit(self) {
  self.conn.commit_count += 1
}

///|
impl @driver.Tx for FakeTx with fn rollback(self) {
  self.conn.rollback_count += 1
}

///|
/// Empty result set: `columns` is `[]` and `next` is immediately false.
priv struct FakeRows {}

///|
impl @driver.Rows for FakeRows with fn columns(self) {
  ignore(self)
  []
}

///|
impl @driver.Rows for FakeRows with fn next(self, _dest) {
  ignore(self)
  false
}

///|
impl @driver.Rows for FakeRows with fn close(self) {
  ignore(self)
}

///|
pub extend FakeConnector with @driver.Connector::{connect}

///|
pub extend FakeConn with @driver.Conn::{
  prepare,
  close,
  begin,
  execute_script,
  is_valid,
  ping,
  ready,
  reset_session,
}
