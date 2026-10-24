///|
/// Open a pooled PostgreSQL database.
///
/// `dsn` is a standard postgres URL:
/// `postgres://user[:password]@host[:port]/database[?params]` (the
/// `postgresql://` scheme is also accepted). Missing pieces default to
/// `localhost`, port `5432`, and `database = user`. The user, password
/// and database components are percent-decoded.
///
/// Supported query parameters:
/// - `sslmode`: `disable`, `verify-ca` or `verify-full`. Defaults to
///   `disable` for local development and test containers (the client
///   library's own default is the strict `verify-full`). The removed
///   libpq aliases `prefer` and `require` are rejected.
/// - `application_name`: defaults to `"moondark"`.
/// - `hostaddr`, `connect_timeout_ms`, `sslrootcert`, `options`,
///   `channel_binding` (`disable`|`prefer`|`require`), `keepalives`
///   (`0`|`1`|`true`|`false`) and `keepalives_idle` (seconds).
///
/// Unknown parameters and malformed values raise `InvalidDsn`.
///
/// Returns the `DB` and its `DBExecutor`; spawn the executor on a task
/// group that outlives the database:
///
/// ```mbt nocheck
/// @async.with_task_group(group => {
///   let (db, executor) = @postgresql_database.open_db(
///     "postgres://user:pass@localhost:5432/db?sslmode=disable",
///   )
///   group.spawn_bg(no_wait=true, () => executor.run())
///   db.ready()
/// })
/// ```
pub fn open_db(
  dsn : String,
  max_idle~ : Int32 = 5,
  max_open~ : Int32 = 10,
  max_lifetime~ : @time.Duration = @time.Duration::zero(),
  max_idle_time~ : @time.Duration = @time.Duration::zero(),
  statement_cache_capacity~ : Int32 = 100,
) -> (@moondark_database.DB, @moondark_database.DBExecutor) raise {
  @moondark_database.DB::create(
    Driver::new().open(dsn),
    max_idle~,
    max_open~,
    max_lifetime~,
    max_idle_time~,
    statement_cache_capacity~,
  )
}

///|
/// Error raised when the DSN passed to `open_db` or `Driver::open` is
/// malformed or carries unsupported parameters.
pub(all) suberror InvalidDsn {
  InvalidDsn(String)
}

///|
/// PostgreSQL driver implementing `@driver.Driver` on top of
/// `moonbit-community/postgres`.
///
/// ```
/// let (db, executor) = @moondark_database.DB::create(@postgresql_database.Driver::new().open("postgres://u:p@h/db"))
/// ```
struct Driver {}

///|
pub fn Driver::new() -> Driver {
  Driver::{ }
}

///|
/// `open` only parses and validates the DSN; the physical connection is
/// established by `Connector::connect` on the pool's task group.
pub impl @driver.Driver for Driver with fn open(_self, dsn) {
  (Connector::{ config: parse_dsn(dsn), } : &@driver.Connector)
}

///|
pub extend Driver with @driver.Driver::{open}

///|
struct Connector {
  config : @client.Config
}

///|
/// Pair a fresh `@client.Client` with the executor driving its protocol
/// loop. The pool spawns `Executor::run` on its own task group and then
/// waits on `Conn::ready`.
pub impl @driver.Connector for Connector with fn connect(self) {
  let (client, executor) = @client.Client::create(self.config)
  (
    (Conn::{ inner: client, } : &@driver.Conn),
    (Executor::{ inner: executor, } : &@driver.ConnExecutor),
  )
}

///|
pub extend Connector with @driver.Connector::{connect}

///|
/// Background task driving one connection's wire protocol; the pool
/// spawns `run` exactly once per physical connection.
struct Executor {
  inner : @client.ClientExecutor
}

///|
pub impl @driver.ConnExecutor for Executor with fn run(self) {
  self.inner.run()
}

///|
pub extend Executor with @driver.ConnExecutor::{run}

///|
struct Conn {
  inner : @client.Client
}

///|
/// Run `f`, reporting errors that prove the operation never reached the
/// server as `@driver.BadConn` so the pool discards the connection and
/// may retry on a fresh one. Errors that kill the connection
/// mid-operation — `Protocol` desyncs, transport EOF and other unknown
/// failures — are re-raised unchanged: the server may already have
/// executed the operation, so retrying could duplicate it. Such a
/// connection is returned to the pool as healthy and discarded by
/// `is_valid` on the next checkout.
async fn[T] Conn::op(_self : Conn, f : async () -> T) -> T {
  f() catch {
    // The client's operation gate rejects work on a closed connection
    // before it reaches the wire, so it was never sent to the server.
    @client.ClientError::Closed(_) as e => raise @driver.BadConn(e)
    e => raise e
  }
}

///|
/// `sql` is sent to the server verbatim and uses PostgreSQL's native
/// `$1`, `$2`, … parameters.
pub impl @driver.Conn for Conn with fn prepare(self, sql) {
  self.op(() => {
    (Stmt::{ conn: self, inner: self.inner.prepare(sql), } : &@driver.Stmt)
  })
}

///|
pub impl @driver.Conn for Conn with fn close(self) {
  self.inner.close()
}

///|
/// `BEGIN` goes through the simple query protocol; `Tx::commit` and
/// `Tx::rollback` issue `COMMIT`/`ROLLBACK` the same way.
pub impl @driver.Conn for Conn with fn begin(self) {
  self.op(() => {
    self.inner.batch_execute("BEGIN")
    (Tx::{ conn: self, } : &@driver.Tx)
  })
}

///|
/// Wait until TCP, TLS, authentication and the first `ReadyForQuery`
/// have completed; the pool calls this after spawning the executor.
pub impl @driver.Conn for Conn with fn ready(self) {
  self.inner.ready()
}

///|
/// Roll back a transaction left open on a reused connection. A failed
/// transaction (status `E`) also reports non-idle and is rolled back.
pub impl @driver.Conn for Conn with fn reset_session(self) {
  if !self.inner.is_transaction_idle() {
    self.op(() => self.inner.batch_execute("ROLLBACK"))
  }
}

///|
/// A connection is valid until the client runtime is closed.
pub impl @driver.Conn for Conn with fn is_valid(self) {
  !self.inner.is_closed()
}

///|
/// `ping` sends a bare `Sync` and waits for `ReadyForQuery`, confirming
/// both directions of the socket are still alive.
pub impl @driver.Conn for Conn with fn ping(self) {
  self.op(() => self.inner.check_connection())
}

///|
/// `batch_execute` sends the whole script through the simple query
/// protocol: the server parses the statements itself (dollar-quoted
/// bodies and all) and runs them in a single implicit transaction —
/// any failing statement rolls back the whole script unless it
/// contains explicit `BEGIN`/`COMMIT`.
pub impl @driver.Conn for Conn with fn batch_execute(self, script) {
  self.op(() => self.inner.batch_execute(script))
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
  batch_execute,
}

///|
struct Tx {
  conn : Conn
}

///|
pub impl @driver.Tx for Tx with fn commit(self) {
  self.conn.op(() => self.conn.inner.batch_execute("COMMIT"))
}

///|
pub impl @driver.Tx for Tx with fn rollback(self) {
  self.conn.op(() => self.conn.inner.batch_execute("ROLLBACK"))
}

///|
pub extend Tx with @driver.Tx::{commit, rollback}

///|
struct Stmt {
  conn : Conn
  inner : @client.Statement
}

///|
/// Wrap a `driver.Value` as a `&ToSql` parameter. Unlike the client's
/// scalar codecs this wrapper accepts every inferred parameter type and
/// always speaks the text wire format, matching `database/sql`
/// expectations: PostgreSQL parses the textual representation itself.
priv struct SqlParam {
  value : @driver.Value
}

///|
impl @client.ToSql for SqlParam with fn accepts(_, _) {
  true
}

///|
impl @client.ToSql for SqlParam with fn format(_, _) {
  Text
}

///|
impl @client.ToSql for SqlParam with fn moonbit_type_name(self) {
  match self.value {
    Null => "Null"
    Bool(_) => "Bool"
    Int64(_) => "Int64"
    Double(_) => "Double"
    String(_) => "String"
    Bytes(_) => "Bytes"
    Timestamp(_) => "Timestamp"
  }
}

///|
impl @client.ToSql for SqlParam with fn to_sql(self, _, buf) {
  match self.value {
    Null => Yes
    Bool(b) => {
      buf.write_string_utf8(if b { "true" } else { "false" })
      No
    }
    Int64(v) => {
      buf.write_string_utf8(v.to_string())
      No
    }
    Double(v) => {
      buf.write_string_utf8(v.to_string())
      No
    }
    String(v) => {
      buf.write_string_utf8(v)
      No
    }
    // `bytea` hex text format: `\x` followed by lowercase hex digits.
    Bytes(v) => {
      buf.write_string_utf8("\\x")
      let digits = b"0123456789abcdef"
      for byte in v {
        buf.write_byte(digits[byte.to_int() >> 4])
        buf.write_byte(digits[byte.to_int() & 0x0f])
      }
      No
    }
    // ISO 8601 with numeric offset, e.g. "2008-08-08T20:00:00+08:00";
    // `ZonedDateTime::to_string` adds a bracketed zone name PostgreSQL
    // cannot parse.
    Timestamp(zdt) => {
      buf.write_string_utf8(zdt.to_plain_date_time().to_string())
      buf.write_string_utf8(zdt.offset().to_string())
      No
    }
  }
}

///|
pub impl @driver.Stmt for Stmt with fn close(self) {
  self.conn.op(() => self.inner.close())
}

///|
/// `Statement::params` is resolved at prepare time, so reporting the
/// real count is cheap and enables the caller-side arity check.
pub impl @driver.Stmt for Stmt with fn num_input(self) {
  self.inner.params().length()
}

///|
/// Execute the prepared statement and drain its result stream for the
/// command tag. `rows_affected` is the trailing count of the tag
/// (`INSERT 0 3`, `UPDATE 2`), or `None` when the tag carries none
/// (DDL such as `CREATE TABLE`). PostgreSQL has no `lastrowid`, so
/// `last_insert_id` is always `None`; use `RETURNING` instead.
pub impl @driver.Stmt for Stmt with fn exec(self, args) {
  self.conn.op(() => {
    let stream = self.conn.inner.query_statement(
      self.inner,
      params=args.map(arg => (SqlParam::{ value: arg, } : &@client.ToSql)),
    )
    let summary = stream.finish()
    let rows_affected : Int64? = match summary.command_tag.split(" ").last() {
      Some(last) => Some(@string.parse_int64(last)) catch { _ => None }
      None => None
    }
    { rows_affected, last_insert_id: None, }
  })
}

///|
pub impl @driver.Stmt for Stmt with fn query(self, args) {
  self.conn.op(() => {
    (
      Rows::{
        conn: self.conn,
        stream: self.conn.inner.query_statement(
          self.inner,
          params=args.map(arg => (SqlParam::{ value: arg, } : &@client.ToSql)),
        ),
      } : &@driver.Rows)
  })
}

///|
pub extend Stmt with @driver.Stmt::{close, num_input, exec, query}

///|
/// Microseconds between the Unix epoch and the PostgreSQL epoch
/// (2000-01-01), the base of binary `timestamp`/`timestamptz` payloads.
const PG_EPOCH_UNIX_MICROS : Int64 = 946_684_800_000_000

///|
struct Rows {
  conn : Conn
  stream : @client.RowStream
}

///|
pub impl @driver.Rows for Rows with fn columns(self) {
  self.stream.columns().map(column => column.name)[:]
}

///|
/// Decode one result field into a `driver.Value`. Result columns arrive
/// in binary format; known scalar OIDs decode through the client's
/// `FromSql` codecs, `timestamp`/`timestamptz`/`date` decode manually,
/// and every other OID falls back to its raw payload bytes.
fn decode_value(
  row : @client.Row,
  index : Int32,
  type_ : @client.Type,
) -> @driver.Value raise {
  guard row.get_raw(index) is Some(raw) else { return Null }
  match type_.oid {
    // bool
    16U => Bool((row.get(index) : Bool))
    // int8
    20U => Int64((row.get(index) : Int64))
    // int2, int4
    21U | 23U => Int64((row.get(index) : Int32).to_int64())
    // float4
    700U => Double((row.get(index) : Float).to_double())
    // float8
    701U => Double((row.get(index) : Double))
    // text, name, varchar (bpchar/citext and friends via name below)
    25U | 19U | 1043U => String((row.get(index) : String))
    // json, jsonb
    114U | 3802U => String((row.get(index) : Json).stringify())
    // bytea, uuid
    17U | 2950U => Bytes((row.get(index) : Bytes))
    // timestamp, timestamptz: int64 microseconds since 2000-01-01.
    // timestamptz is UTC; naive timestamp is interpreted as UTC too.
    1114U | 1184U => {
      let micros = @proto.ByteReader::new(raw[:]).read_i64_be() +
        PG_EPOCH_UNIX_MICROS
      let nanos_part = (micros % 1_000_000 + 1_000_000) % 1_000_000
      Timestamp(
        @time.ZonedDateTime::from_unix_second(
          (micros - nanos_part) / 1_000_000,
          nanosecond=nanos_part.to_int() * 1000,
          zone=@time.utc_zone,
        ),
      )
    }
    // date: int32 days since 2000-01-01, returned as UTC midnight.
    1082U => {
      let days = @proto.ByteReader::new(raw[:]).read_i32_be().to_int64() +
        10_957
      Timestamp(
        @time.ZonedDateTime::from_unix_second(
          days * 86_400,
          zone=@time.utc_zone,
        ),
      )
    }
    _ =>
      // Text-like extension types decode as strings; anything else
      // falls back to the raw binary payload.
      if type_.name
        is ("bpchar" | "citext" | "lquery" | "ltree" | "ltxtquery" | "unknown") {
        String((row.get(index) : String))
      } else {
        Bytes(raw)
      }
  }
}

///|
pub impl @driver.Rows for Rows with fn next(self, dest) {
  self.conn.op(() => {
    match self.stream.next() {
      None => false
      Some(row) => {
        let columns = row.columns()
        for i in 0..<dest.length() {
          dest[i] = decode_value(row, i, columns[i].type_)
        }
        true
      }
    }
  })
}

///|
/// Draining the stream releases the connection's operation permit and
/// reports any server error queued behind the consumed rows.
pub impl @driver.Rows for Rows with fn close(self) {
  self.conn.op(() => ignore(self.stream.finish()))
}

///|
pub extend Rows with @driver.Rows::{close, columns, next}

///|
/// Parse a `postgres://`/`postgresql://` URL into a `@client.Config`.
/// See `open_db` for the accepted syntax and defaults.
///
/// `Config::new_internal` is the only constructor forwarding `T?`
/// fields; `Config::Config` takes plain `T` for its optional arguments.
#warnings("-alert_internal")
fn parse_dsn(dsn : String) -> @client.Config raise {
  let rest = if dsn.has_prefix("postgres://") {
    dsn[11:].to_owned()
  } else if dsn.has_prefix("postgresql://") {
    dsn[13:].to_owned()
  } else {
    raise InvalidDsn("expected a postgres:// or postgresql:// URL: \{dsn}")
  }
  let (authority, query) = match rest.find("?") {
    Some(i) => (rest[:i].to_owned(), Some(rest[i + 1:].to_owned()))
    None => (rest, None)
  }
  let (authority, database_path) = match authority.find("/") {
    Some(i) => (authority[:i].to_owned(), authority[i + 1:].to_owned())
    None => (authority, "")
  }
  let (userinfo, hostport) = match authority.rev_find("@") {
    Some(i) => (authority[:i], authority[i + 1:].to_owned())
    None => ("", authority)
  }
  let (user, password) = match userinfo.find(":") {
    Some(i) =>
      (
        percent_decode(userinfo[:i].to_owned()),
        Some(percent_decode(userinfo[i + 1:].to_owned())),
      )
    None => (percent_decode(userinfo.to_owned()), None)
  }
  guard !user.is_empty() else {
    raise InvalidDsn("missing user in DSN: \{dsn}")
  }
  let (host, port) = parse_hostport(hostport)
  let database = if database_path.is_empty() {
    user
  } else {
    percent_decode(database_path)
  }
  let mut ssl_mode = @client.SslMode::Disable
  let mut channel_binding = @client.ChannelBinding::Disable
  let mut application_name = "moondark"
  let mut hostaddr : String? = None
  let mut ssl_root_cert : String? = None
  let mut options : String? = None
  let mut connect_timeout_ms : Int32? = None
  let mut keepalives : Bool? = None
  let mut keepalives_idle_s : Int32? = None
  if query is Some(query) {
    for pair in query.split("&") {
      guard pair.find("=") is Some(eq) else {
        raise InvalidDsn("malformed DSN parameter: \{pair}")
      }
      let key = percent_decode(pair[:eq].to_owned())
      let value = percent_decode(pair[eq + 1:].to_owned())
      match key {
        "sslmode" =>
          ssl_mode = match value {
            "disable" => @client.SslMode::Disable
            "verify-ca" => @client.SslMode::VerifyCa
            "verify-full" => @client.SslMode::VerifyFull
            _ =>
              raise InvalidDsn(
                "unsupported sslmode \{value}: use disable, verify-ca or verify-full",
              )
          }
        "channel_binding" =>
          channel_binding = match value {
            "disable" => @client.ChannelBinding::Disable
            "prefer" => @client.ChannelBinding::Prefer
            "require" => @client.ChannelBinding::Require
            _ => raise InvalidDsn("unsupported channel_binding \{value}")
          }
        "application_name" => application_name = value
        "hostaddr" => hostaddr = Some(value)
        "sslrootcert" => ssl_root_cert = Some(value)
        "options" => options = Some(value)
        "connect_timeout_ms" =>
          connect_timeout_ms = Some(
            @string.parse_int(value) catch {
              _ => raise InvalidDsn("invalid connect_timeout_ms: \{value}")
            },
          )
        "keepalives" =>
          keepalives = Some(
            match value {
              "0" | "false" => false
              "1" | "true" => true
              _ => raise InvalidDsn("invalid keepalives: \{value}")
            },
          )
        "keepalives_idle" =>
          keepalives_idle_s = Some(
            @string.parse_int(value) catch {
              _ => raise InvalidDsn("invalid keepalives_idle: \{value}")
            },
          )
        _ => raise InvalidDsn("unsupported DSN parameter: \{key}")
      }
    }
  }
  @client.Config::new_internal(
    host, hostaddr, port, user, database, password, ssl_mode, ssl_root_cert, channel_binding,
    application_name, options, connect_timeout_ms, keepalives, keepalives_idle_s,
  )
}

///|
/// Split a DSN authority's `host[:port]` part, accepting `[v6addr]:port`
/// bracketed IPv6 literals. Empty host defaults to `localhost` and a
/// missing port defaults to `5432`.
fn parse_hostport(hostport : String) -> (String, Int32) raise {
  let (host, port_str) = if hostport.has_prefix("[") {
    guard hostport.find("]") is Some(close) else {
      raise InvalidDsn("unterminated IPv6 host: \{hostport}")
    }
    let host = hostport[1:close].to_owned()
    if hostport[close + 1:].has_prefix(":") {
      (host, hostport[close + 2:].to_owned())
    } else {
      (host, "")
    }
  } else {
    match hostport.find(":") {
      Some(i) => (hostport[:i].to_owned(), hostport[i + 1:].to_owned())
      None => (hostport, "")
    }
  }
  if port_str.is_empty() {
    (if host.is_empty() { "localhost" } else { host }, 5432)
  } else {
    (
      if host.is_empty() {
        "localhost"
      } else {
        host
      },
      @string.parse_int(port_str) catch {
        _ => raise InvalidDsn("invalid port: \{port_str}")
      },
    )
  }
}

///|
/// Percent-decode a DSN component, reporting malformed escapes as
/// `InvalidDsn`.
fn percent_decode(s : String) -> String raise {
  @percent.decode(s[:]) catch {
    _ => raise InvalidDsn("invalid percent-encoding: \{s}")
  }
}
