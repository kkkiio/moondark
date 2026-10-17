///|
/// A prepared statement. Like `sql.Stmt` in Go, it can be reused
/// concurrently; a physical prepared statement is cached per pooled
/// connection and re-prepared lazily on each new connection.
pub struct Stmt {
  query : String
  /// The pool unbound statements acquire connections from.
  priv pool : Pool
  /// Bound to a specific connection when created via `Conn::prepare`;
  /// unbound statements (via `DB::prepare`) run on any pooled conn.
  priv bound : Conn?
  priv mut closed : Bool
  /// conn entry id -> live prepared driver statement
  priv handles : Map[Int64, ConnStmt]
}

///|
/// Execute the prepared statement with `params` and return its result.
/// Unbound statements retry `BadConn` failures on a fresh connection;
/// bound statements discard the dead connection and propagate the error.
pub async fn Stmt::execute(
  self : Self,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> ExecResult {
  if self.closed {
    fail("use of closed statement")
  }
  match self.bound {
    Some(conn) => {
      let entry = self.bound_entry()
      let executed : Result[ExecResult, Error] = Ok(
        exec_stmt(self.cached_on(entry).stmt, params),
      ) catch {
        e => Err(e)
      }
      match executed {
        Ok(result) => result
        Err(e) => {
          if e is @driver.BadConn(_) {
            self.pool.release(entry, bad=true)
            conn.entry = None
          }
          raise e
        }
      }
    }
    None => {
      for attempt in 0..<=max_bad_conn_retries {
        let entry = match acquire_retry(self.pool, attempt) {
          Some(entry) => entry
          None => continue
        }
        let executed : Result[ExecResult, Error] = Ok(
          exec_stmt(self.cached_on(entry).stmt, params),
        ) catch {
          e => Err(e)
        }
        match executed {
          Ok(result) => {
            self.pool.release(entry)
            return result
          }
          Err(e) =>
            if release_failed(self.pool, entry, e, attempt) {
              continue
            } else {
              raise e
            }
        }
      }
      panic() // the last attempt either returns or raises
    }
  }
}

///|
/// Run the prepared statement with `params` and return its result rows.
/// Unbound statements keep the connection checked out until
/// `Rows::close` returns it to the pool; the cached driver statement is
/// not closed with the rows.
pub async fn Stmt::query(
  self : Self,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> Rows {
  if self.closed {
    fail("use of closed statement")
  }
  match self.bound {
    Some(conn) => {
      let entry = self.bound_entry()
      let queried : Result[(&@driver.Stmt, &@driver.Rows), Error] = Ok(
        {
          let cs = self.cached_on(entry)
          (cs.stmt, query_rows(cs.stmt, params))
        },
      ) catch {
        e => Err(e)
      }
      match queried {
        Ok((stmt, rows)) =>
          Rows::{
            conn: entry,
            stmt,
            rows,
            pool: None,
            close_stmt: false,
            closed: false,
          }
        Err(e) => {
          if e is @driver.BadConn(_) {
            self.pool.release(entry, bad=true)
            conn.entry = None
          }
          raise e
        }
      }
    }
    None => {
      for attempt in 0..<=max_bad_conn_retries {
        let entry = match acquire_retry(self.pool, attempt) {
          Some(entry) => entry
          None => continue
        }
        let queried : Result[(&@driver.Stmt, &@driver.Rows), Error] = Ok(
          {
            let cs = self.cached_on(entry)
            (cs.stmt, query_rows(cs.stmt, params))
          },
        ) catch {
          e => Err(e)
        }
        match queried {
          Ok((stmt, rows)) =>
            // Success: the connection is released later by
            // `Rows::close`; the cached statement stays open.
            return Rows::{
              conn: entry,
              stmt,
              rows,
              pool: Some(self.pool),
              close_stmt: false,
              closed: false,
            }
          Err(e) =>
            if release_failed(self.pool, entry, e, attempt) {
              continue
            } else {
              raise e
            }
        }
      }
      panic() // the last attempt either returns or raises
    }
  }
}

///|
/// Close the statement and every driver statement cached for it, on
/// every pooled connection it was prepared on. Idempotent; executing or
/// querying a closed statement raises `use of closed statement`.
pub async fn Stmt::close(self : Self) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for _, cs in self.handles {
    cs.stmt.close() catch {
      _ => ()
    }
    cs.entry.stmt_cache.remove(self.query)
  }
  self.handles.clear()
}

///|
/// The entry a bound statement runs on: the bound conn's checked-out
/// entry, acquiring a fresh connection if the previous one died.
async fn Stmt::bound_entry(self : Stmt) -> ConnEntry {
  guard self.bound is Some(conn) else { panic() }
  if conn.closed {
    fail("use of closed connection")
  }
  match conn.entry {
    Some(entry) => entry
    None => {
      let entry = conn.pool.acquire()
      conn.entry = Some(entry)
      entry
    }
  }
}

///|
/// Return the driver statement for `self` prepared on `entry',
/// preparing and caching it on a cache miss. The per-connection cache
/// is LRU: hits move the entry to newest (re-inserted at the end), and
/// inserts evict the oldest (first-iterated) statement once
/// `max_stmts_per_conn` is exceeded.
async fn Stmt::cached_on(self : Stmt, entry : ConnEntry) -> ConnStmt {
  match entry.stmt_cache.get(self.query) {
    Some(cs) => {
      // Bump LRU order: removing and re-setting moves the entry to
      // newest in the insertion-ordered map.
      entry.stmt_cache.remove(self.query)
      entry.stmt_cache[self.query] = cs
      cs
    }
    None => {
      let cs = ConnStmt::{
        entry,
        stmt: entry.conn.prepare(self.query),
        owner: self,
      }
      entry.stmt_cache[self.query] = cs
      self.handles[entry.id] = cs
      let max_stmts = self.pool.max_stmts_per_conn
      if max_stmts > 0 && entry.stmt_cache.length() > max_stmts {
        // Evict the least recently used statement: the first key in
        // insertion order.
        if entry.stmt_cache.iter().next() is Some((key, evicted)) {
          entry.stmt_cache.remove(key)
          evicted.owner.handles.remove(entry.id)
          evicted.stmt.close() catch {
            _ => ()
          }
        }
      }
      cs
    }
  }
}

///|
/// A driver statement prepared on a specific pooled connection,
/// cross-referenced by the `Stmt` that owns it so both cache eviction
/// and `Stmt::close` can find and close it.
priv struct ConnStmt {
  entry : ConnEntry
  stmt : &@driver.Stmt
  owner : Stmt
}

///|
fn values_of(params : ArrayView[&@driver.Valuer]) -> Array[@driver.Value] {
  params.map(fn(param) { param.to_value() })
}

///|
/// Check the number of parameters against the prepared statement.
/// `num_input` may return a negative value to skip the check.
fn check_num_input(
  stmt : &@driver.Stmt,
  params : ArrayView[&@driver.Valuer],
) -> Unit raise {
  let expected = stmt.num_input()
  if expected >= 0 && expected != params.length() {
    fail("expected \{expected} parameters, got \{params.length()}")
  }
}

///|
async fn query_rows(
  stmt : &@driver.Stmt,
  params : ArrayView[&@driver.Valuer],
) -> &@driver.Rows {
  check_num_input(stmt, params)
  stmt.query(values_of(params))
}

///|
async fn exec_stmt(
  stmt : &@driver.Stmt,
  params : ArrayView[&@driver.Valuer],
) -> ExecResult {
  check_num_input(stmt, params)
  stmt.exec(values_of(params))
}
