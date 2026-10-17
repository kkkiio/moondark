///|
/// Open a pooled SQLite database.
///
/// `dsn` is a filename passed to `sqlite3_open_v2` (e.g. `"app.db"` or
/// `":memory:"`). Note that each pooled connection to `":memory:"` gets its
/// own private database; use `max_open=1` or a file for shared state.
///
/// Returns the `DB` and its `DBExecutor`; spawn the executor on a task
/// group that outlives the database:
///
/// ```
/// let (db, executor) = @moondark_sqlite.open_db("app.db")
/// group.spawn_bg(no_wait=true, () => executor.run())
/// ```
pub fn open_db(
  dsn : String,
  max_idle~ : Int32 = 5,
  max_open~ : Int32 = 10,
  max_lifetime~ : @time.Duration = @time.Duration::zero(),
  max_idle_time~ : @time.Duration = @time.Duration::zero(),
) -> (@sql.DB, @sql.DBExecutor) raise {
  @sql.DB::create(
    Driver::new().open(dsn),
    max_idle~,
    max_open~,
    max_lifetime~,
    max_idle_time~,
  )
}

///|
/// SQLite driver implementing `@driver.Driver`.
///
/// ```
/// let (db, executor) = @sql.DB::create(@moondark_sqlite.Driver::new().open("app.db"))
/// ```
struct Driver {}

///|
pub fn Driver::new() -> Driver {
  Driver::{ }
}

///|
/// `open` does not touch the filesystem; every `connect` opens a fresh
/// `sqlite3.Connection` in serialized (FULLMUTEX) mode.
pub impl @driver.Driver for Driver with fn open(_self, dsn) {
  Connector::{ dsn, }
}

///|
pub extend Driver with @driver.Driver::{open}

///|
struct Connector {
  dsn : String
}

///|
/// SQLite connections are self-sufficient: `connect` pairs the fresh
/// `sqlite3.Connection` with a `@driver.NoopExecutor`.
pub impl @driver.Connector for Connector with fn connect(self) {
  (
    (Conn::{ inner: @sqlite3.Connection::open_async(self.dsn), } : &@driver.Conn),
    @driver.NoopExecutor::{ },
  )
}

///|
pub extend Connector with @driver.Connector::{connect}

///|
struct Conn {
  inner : @sqlite3.Connection
}

///|
pub impl @driver.Conn for Conn with fn prepare(self, sql) {
  Stmt::{ inner: self.inner.prepare_async(sql), conn: self.inner, }
}

///|
pub impl @driver.Conn for Conn with fn close(self) {
  self.inner.close()
}

///|
pub impl @driver.Conn for Conn with fn begin(self) {
  let stmt = self.inner.prepare_async("BEGIN")
  defer stmt.finalize()
  ignore(stmt.step_async())
  Tx::{ conn: self.inner, }
}

///|
/// SQLite connections are in-process; they stay valid until `close`.
pub impl @driver.Conn for Conn with fn is_valid(_self) {
  true
}

///|
/// `ping` runs `SELECT 1` to verify the connection is still alive.
pub impl @driver.Conn for Conn with fn ping(self) {
  let stmt = self.inner.prepare_async("SELECT 1")
  defer stmt.finalize()
  ignore(stmt.step_async())
}

///|
pub extend Conn with @driver.Conn::{
  begin,
  close,
  prepare,
  is_valid,
  ping,
  ready,
  reset_session,
}

///|
struct Tx {
  conn : @sqlite3.Connection
}

///|
pub impl @driver.Tx for Tx with fn commit(self) {
  let stmt = self.conn.prepare_async("COMMIT")
  defer stmt.finalize()
  ignore(stmt.step_async())
}

///|
pub impl @driver.Tx for Tx with fn rollback(self) {
  let stmt = self.conn.prepare_async("ROLLBACK")
  defer stmt.finalize()
  ignore(stmt.step_async())
}

///|
pub extend Tx with @driver.Tx::{commit, rollback}

///|
struct Stmt {
  inner : @sqlite3.Statement
  conn : @sqlite3.Connection
}

///|
fn Stmt::bind(self : Stmt, args : Array[@driver.Value]) -> Unit raise {
  for i, arg in args {
    let value : @sqlite3.Value = match arg {
      Null => Null
      Bool(b) => Integer(if b { 1 } else { 0 })
      Int64(v) => Integer(v)
      Double(v) => Real(v)
      String(v) => Text(v)
      Bytes(v) => Blob(v)
      // ISO 8601 text, readable by SQLite's date and time functions.
      Timestamp(zdt) => Text(zdt.to_string())
    }
    self.inner.bind(index=i + 1, value)
  }
}

///|
pub impl @driver.Stmt for Stmt with fn close(self) {
  self.inner.finalize()
}

///|
/// `sqlite3_bind_parameter_count` is not exposed by the sqlite3 bindings;
/// return a negative number to skip the caller-side parameter count check.
pub impl @driver.Stmt for Stmt with fn num_input(_self) {
  -1
}

///|
pub impl @driver.Stmt for Stmt with fn exec(self, args) {
  self.bind(args)
  let mut changes : Int64? = None
  while true {
    match self.inner.step_async() {
      Row => ()
      Done(changes=done) => {
        changes = done
        break
      }
    }
  }
  let last_insert_id = match changes {
    Some(_) => {
      // sqlite3_last_insert_rowid is not exposed; probe it on the same
      // connection so the job runs after the write on this executor.
      let probe = self.conn.prepare_async("SELECT last_insert_rowid()")
      defer probe.finalize()
      if probe.step_async() is Row {
        match (probe.column(index=0) : Int64) {
          0 => None
          id => Some(id)
        }
      } else {
        None
      }
    }
    None => None
  }
  { rows_affected: changes, last_insert_id, }
}

///|
pub impl @driver.Stmt for Stmt with fn query(self, args) {
  self.bind(args)
  let columns = []
  for i in 0..<self.inner.column_count() {
    columns.push(self.inner.column_name(index=i))
  }
  Rows::{ inner: self.inner, columns, }
}

///|
pub extend Stmt with @driver.Stmt::{close, num_input, exec, query}

///|
struct Rows {
  inner : @sqlite3.Statement
  columns : Array[String]
}

///|
pub impl @driver.Rows for Rows with fn columns(self) {
  self.columns
}

///|
pub impl @driver.Rows for Rows with fn next(self, dest) {
  guard self.inner.step_async() is Row else { return false }
  for i in 0..<dest.length() {
    let value : @sqlite3.Value = self.inner.column(index=i)
    dest[i] = match value {
      Null => Null
      Integer(v) => Int64(v)
      Real(v) => Double(v)
      Text(v) => String(v)
      Blob(v) => Bytes(v)
    }
  }
  true
}

///|
pub impl @driver.Rows for Rows with fn close(self) {
  self.inner.finalize()
}

///|
pub extend Rows with @driver.Rows::{close, columns, next}
