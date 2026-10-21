///|
/// Open a pooled MySQL database.
///
/// `dsn` accepts either of the shapes a `@mysql.MySqlContainer` handle
/// produces:
///
/// * a MySQL URI — `mysql://user[:password]@host[:port]/database`
///   (`MySqlContainer::connection_string`); user, password and database are
///   percent-decoded.
/// * a Go-style DSN — `user:password@tcp(host:port)/database`
///   (`MySqlContainer::dsn`).
///
/// The port defaults to 3306 and an empty host to `127.0.0.1`. Query
/// parameters and Unix-socket forms are not supported.
///
/// Returns the `DB` and its `DBExecutor`; spawn the executor on a task
/// group that outlives the database:
///
/// ```
/// let (db, executor) = @mysql_database.open_db("mysql://root@127.0.0.1/app")
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
/// MySQL driver implementing `@driver.Driver` on top of moonmysql's async
/// `MysqlConn` (text protocol over a raw socket; each pooled connection owns
/// its socket for its whole lifetime, so `begin`/`commit`/`rollback` bracket
/// a real server-side transaction).
///
/// ```
/// let (db, executor) = @sql.DB::create(@mysql_database.Driver::new().open("mysql://u:p@h/db"))
/// ```
struct Driver {}

///|
pub fn Driver::new() -> Driver {
  Driver::{ }
}

///|
/// `open` only parses and validates the DSN — no network traffic. The real
/// handshake happens per connection in `Connector::connect`.
pub impl @driver.Driver for Driver with fn open(_self, dsn) {
  parse_dsn(dsn)
}

///|
pub extend Driver with @driver.Driver::{open}

///|
struct Connector {
  host : String
  port : Int32
  user : String
  password : String
  database : String
}

///|
/// Parse the DSN eagerly so a malformed string fails in `open` rather than
/// on the first pooled connect.
fn parse_dsn(dsn : String) -> Connector raise {
  if dsn.has_prefix("mysql://") {
    return parse_uri_dsn(dsn)
  }
  parse_go_dsn(dsn)
}

///|
/// `mysql://user[:password]@host[:port]/database`. The userinfo/host split
/// uses the last `@` before the path (a literal `@` inside credentials is
/// percent-encoded by producers); IPv6 hosts keep their `[…]` brackets.
fn parse_uri_dsn(dsn : String) -> Connector raise {
  let body = dsn[8:]
  guard body.find("/") is Some(slash) else {
    fail("malformed MySQL DSN '\{dsn}': missing /database")
  }
  let authority = body[:slash]
  let database = decode_part(body[slash + 1:])
  guard authority.rev_find("@") is Some(at) else {
    fail("malformed MySQL DSN '\{dsn}': missing user@")
  }
  let userinfo = authority[:at]
  let hostport = authority[at + 1:]
  let (user, password) = match userinfo.find(":") {
    Some(i) => (decode_part(userinfo[:i]), decode_part(userinfo[i + 1:]))
    None => (decode_part(userinfo), "")
  }
  let (host, port) = parse_host_port(hostport, dsn)
  Connector::{ host, port, user, password, database, }
}

///|
/// Go-style `user:password@tcp(host:port)/database` used by go-sql-driver
/// and emitted by `MySqlContainer::dsn`. Values are taken verbatim (this
/// form is not percent-encoded).
fn parse_go_dsn(dsn : String) -> Connector raise {
  guard dsn.find("@tcp(") is Some(at) else {
    fail(
      "malformed MySQL DSN '\{dsn}': expected mysql://user[:password]@host[:port]/db or user:password@tcp(host:port)/db",
    )
  }
  let userinfo = dsn[:at]
  let rest = dsn[at + 5:]
  guard rest.find(")") is Some(close) else {
    fail("malformed MySQL DSN '\{dsn}': unclosed tcp(…)")
  }
  let hostport = rest[:close]
  let path = rest[close + 1:]
  let database = if path.has_prefix("/") {
    path[1:].to_owned()
  } else {
    path.to_owned()
  }
  let (user, password) = match userinfo.find(":") {
    Some(i) => (userinfo[:i].to_owned(), userinfo[i + 1:].to_owned())
    None => (userinfo.to_owned(), "")
  }
  let (host, port) = parse_host_port(hostport, dsn)
  Connector::{ host, port, user, password, database, }
}

///|
/// Percent-decode one DSN component; a malformed `%` sequence keeps the raw
/// text rather than failing the whole DSN.
fn decode_part(part : StringView) -> String {
  @percent.decode(part) catch {
    _ => part.to_owned()
  }
}

///|
/// Split `host[:port]` honouring `[ipv6]` brackets; empty host falls back to
/// `127.0.0.1`, missing port to 3306.
fn parse_host_port(
  hostport : StringView,
  dsn : String,
) -> (String, Int32) raise {
  if hostport.has_prefix("[") {
    guard hostport.find("]") is Some(close) else {
      fail("malformed MySQL DSN '\{dsn}': unclosed [ipv6]")
    }
    let host = hostport[1:close].to_owned()
    let rest = hostport[close + 1:]
    let port = if rest.has_prefix(":") {
      parse_port(rest[1:], dsn)
    } else {
      3306
    }
    return (host, port)
  }
  match hostport.rev_find(":") {
    Some(i) =>
      (
        if i == 0 {
          "127.0.0.1"
        } else {
          hostport[:i].to_owned()
        },
        parse_port(hostport[i + 1:], dsn),
      )
    None =>
      (if hostport == "" { "127.0.0.1" } else { hostport.to_owned() }, 3306)
  }
}

///|
fn parse_port(text : StringView, dsn : String) -> Int32 raise {
  let port = @string.parse_int(text) catch {
    _ => fail("malformed MySQL DSN '\{dsn}': bad port '\{text}'")
  }
  guard port > 0 && port <= 65535 else {
    fail("malformed MySQL DSN '\{dsn}': port out of range '\{text}'")
  }
  port
}

///|
/// `connect` performs the full async handshake (auth + sql_mode probe) and
/// returns the live socket. `MysqlConn` issues its own socket round trips,
/// so no protocol executor is needed — the pair's second half is a
/// `@driver.NoopExecutor`. Connection failures surface as `BadConn` so the
/// pool may retry acquisition.
pub impl @driver.Connector for Connector with fn connect(self) {
  let inner = @client.MysqlConn::connect(
    self.host,
    self.port,
    self.user,
    self.password,
    self.database,
  ) catch {
    e => raise @driver.BadConn(e)
  }
  ((Conn::{ inner, } : &@driver.Conn), @driver.NoopExecutor::{ })
}

///|
pub extend Connector with @driver.Connector::{connect}

///|
struct Conn {
  inner : @client.MysqlConn
}

///|
/// A statement is just the SQL text plus the connection — the text protocol
/// renders parameters as escaped literals, so there is no server-side
/// prepared statement to hold.
pub impl @driver.Conn for Conn with fn prepare(self, sql) {
  Stmt::{ conn: self.inner, sql, num_input: count_placeholders(sql), }
}

///|
pub impl @driver.Conn for Conn with fn close(self) {
  self.inner.close()
}

///|
pub impl @driver.Conn for Conn with fn begin(self) {
  self.inner.begin() catch {
    e => raise classify(e)
  }
  Tx::{ conn: self.inner, }
}

///|
/// The socket stays valid until `close` (or a transport error marks the
/// connection unusable through `BadConn`).
pub impl @driver.Conn for Conn with fn is_valid(self) {
  !self.inner.closed
}

///|
/// `ping` runs `SELECT 1` to verify the connection is still alive. A failed
/// ping means the socket is dead: transport errors become `BadConn` so the
/// pool discards the connection; a `ServerError` would mean the server
/// answered and the connection is fine, so it propagates as-is.
pub impl @driver.Conn for Conn with fn ping(self) {
  ignore(self.inner.query("SELECT 1", []) catch { e => raise classify(e) })
}

///|
/// `reset_session` rolls back any transaction a previous checkout left open
/// (e.g. a `db.conn()` caller that never committed) before the pooled
/// connection is reused. `ROLLBACK` outside a transaction is a harmless
/// no-op on MySQL; autocommit itself needs no reset.
pub impl @driver.Conn for Conn with fn reset_session(self) {
  self.inner.rollback() catch {
    e => raise classify(e)
  }
}

///|
/// `execute_script` is unsupported: moonmysql's text protocol is
/// single-statement (`CLIENT_MULTI_STATEMENTS` is not negotiated).
pub impl @driver.Conn for Conn with fn execute_script(_self, _script) {
  fail("mysql: execute_script is not supported by the moonmysql client")
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
  execute_script,
}

///|
struct Tx {
  conn : @client.MysqlConn
}

///|
pub impl @driver.Tx for Tx with fn commit(self) {
  self.conn.commit() catch {
    e => raise classify(e)
  }
}

///|
pub impl @driver.Tx for Tx with fn rollback(self) {
  self.conn.rollback() catch {
    e => raise classify(e)
  }
}

///|
pub extend Tx with @driver.Tx::{commit, rollback}

///|
struct Stmt {
  conn : @client.MysqlConn
  sql : String
  num_input : Int32
}

///|
/// Nothing to release — text-protocol statements hold no server resources.
pub impl @driver.Stmt for Stmt with fn close(_self) {
  ()
}

///|
/// The number of `?` placeholders, counted with the same quoting rules
/// moonmysql's binder uses (single/double/backtick quotes, backslash
/// escapes), so the caller-side count check matches what will be sent.
pub impl @driver.Stmt for Stmt with fn num_input(self) {
  self.num_input
}

///|
pub impl @driver.Stmt for Stmt with fn exec(self, args) {
  let result = self.conn.execute(self.sql, to_moondb(args)) catch {
    e => raise classify(e)
  }
  {
    rows_affected: Some(result.rows_affected),
    // The OkPacket reports 0 when the statement generated no id.
    last_insert_id: if result.last_insert_id == 0 {
      None
    } else {
      Some(result.last_insert_id)
    },
  }
}

///|
/// `query` opens a wire-level cursor (`query_stream`): column metadata is
/// consumed up front — so `columns()` is correct even for an empty result —
/// and each `next` reads one row packet off the socket. The stream locks the
/// connection until drained or `close`d, which `Rows::close` guarantees.
pub impl @driver.Stmt for Stmt with fn query(self, args) {
  let stream = self.conn.query_stream(self.sql, to_moondb(args)) catch {
    e => raise classify(e)
  }
  Rows::{ stream, columns: stream.columns.map(fn(c) { c.name }), }
}

///|
pub extend Stmt with @driver.Stmt::{close, num_input, exec, query}

///|
struct Rows {
  stream : @client.MysqlRowStream
  columns : Array[String]
}

///|
pub impl @driver.Rows for Rows with fn columns(self) {
  self.columns
}

///|
pub impl @driver.Rows for Rows with fn next(self, dest) {
  let row = self.stream.next() catch { e => raise classify(e) }
  guard row is Some(row) else { return false }
  for i in 0..<dest.length() {
    dest[i] = if i < row.values.length() {
      from_moondb(row.values[i])
    } else {
      Null
    }
  }
  true
}

///|
/// `close` drains any unread rows to the terminating EOF so the connection
/// can run the next statement; idempotent once the stream is done.
pub impl @driver.Rows for Rows with fn close(self) {
  self.stream.close()
}

///|
pub extend Rows with @driver.Rows::{close, columns, next}

///|
/// Map driver values onto moondb's closed sum. `Timestamp` is rendered as
/// local ISO-8601 text (`YYYY-MM-DDTHH:MM:SS`) which MySQL accepts for
/// DATE/DATETIME/TIMESTAMP literals — lossy: the zone/offset is dropped.
fn to_moondb(args : Array[@driver.Value]) -> Array[@moondb.Value] {
  args.map(fn(arg) {
    match arg {
      Null => @moondb.Null
      Bool(b) => Bool(b)
      Int64(v) => Int64(v)
      Double(v) => Double(v)
      String(v) => Text(v)
      Bytes(v) => Blob(v)
      Timestamp(zdt) => Text(zdt.to_plain_date_time().to_string())
    }
  })
}

///|
/// Map wire values back. moondb `Int` widens to `Int64`. Note MySQL has no
/// native boolean: a BOOL/TINYINT(1) column reads back as `Int64(0|1)`, and
/// temporal columns arrive as `Text` (ISO strings) — both documented limits
/// of the text protocol's type surface.
fn from_moondb(v : @moondb.Value) -> @driver.Value {
  match v {
    Null => Null
    Bool(b) => Bool(b)
    Int(v) => Int64(v.to_int64())
    Int64(v) => Int64(v)
    Double(v) => Double(v)
    Text(v) => String(v)
    Blob(v) => Bytes(v)
  }
}

///|
/// Classify a failure from the wire. `ServerError` is a statement-level
/// rejection (syntax error, constraint violation, missing table): the server
/// answered, so the connection is healthy and the error propagates as-is.
/// Everything else — transport/socket failures, protocol desync, `Closed`,
/// unsupported-plugin errors — means the connection can no longer be trusted
/// and becomes `BadConn`, which tells the pool to discard it and (when the
/// operation never reached the server) retry on a fresh connection.
fn classify(e : Error) -> Error {
  if e is @moonmysql.MysqlError::ServerError(_, _, _) {
    e
  } else {
    @driver.BadConn(e)
  }
}

///|
/// Count `?` placeholders outside single-, double- and backtick-quoted
/// spans, honouring backslash escapes — the same scanning rules as
/// moonmysql's `bind_params`, so `num_input` never disagrees with the
/// binder's own count check.
fn count_placeholders(sql : String) -> Int32 {
  let mut count = 0
  let mut single = false
  let mut double = false
  let mut back = false
  let mut escaped = false
  for c in sql {
    if escaped {
      escaped = false
      continue
    }
    if single || double {
      if c == '\\' {
        escaped = true
      } else if (single && c == '\'') || (double && c == '"') {
        single = false
        double = false
      }
    } else if back {
      if c == '`' {
        back = false
      }
    } else if c == '\'' {
      single = true
    } else if c == '"' {
      double = true
    } else if c == '`' {
      back = true
    } else if c == '?' {
      count += 1
    }
  }
  count
}
