///|
/// A dedicated connection checked out of the pool. Like `sql.Conn` in
/// Go, it is not shared until `close` returns it to the pool. If the
/// underlying connection dies (`BadConn`), the next operation acquires
/// a fresh one automatically.
pub struct Conn {
  priv pool : Pool
  priv mut entry : ConnEntry?
  priv mut closed : Bool
}

///|
/// Return the connection to the pool. Subsequent calls are no-ops and
/// subsequent operations raise `use of closed connection`.
pub async fn Conn::close(self : Self) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if self.entry is Some(entry) {
    self.entry = None
    self.pool.release(entry)
  }
}

///|
/// Verify the checked-out connection is still alive, acquiring a fresh
/// one if the previous connection was discarded. Failures with
/// `BadConn` are retried on a fresh connection.
pub async fn Conn::ping(self : Self) -> Unit {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match self.acquire_entry(attempt) {
      Some(entry) => entry
      None => continue
    }
    let result : Result[Unit, Error] = Ok(entry.conn.ping()) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => return
      Err(e) =>
        if self.fail_entry(entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
  }
}

///|
/// Run `query` on the dedicated connection and return its result rows.
/// The connection stays checked out: `Rows::close` closes the result
/// but does not return the connection to the pool. Failures with
/// `BadConn` are retried on a fresh connection.
pub async fn Conn::query(
  self : Self,
  query : String,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> Rows {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match self.acquire_entry(attempt) {
      Some(entry) => entry
      None => continue
    }
    // Capture errors so the statement can be closed before the error
    // propagates.
    let result : Result[(&@driver.Stmt, &@driver.Rows), Error] = Ok(
      {
        let stmt = entry.conn.prepare(query)
        let queried : Result[&@driver.Rows, Error] = Ok(
          query_rows(stmt, params),
        ) catch {
          e => Err(e)
        }
        match queried {
          Ok(rows) => (stmt, rows)
          Err(e) => {
            stmt.close() catch {
              _ => ()
            }
            raise e
          }
        }
      },
    ) catch {
      e => Err(e)
    }
    match result {
      Ok((stmt, rows)) =>
        return Rows::{
          conn: entry,
          stmt,
          rows,
          pool: None,
          close_stmt: true,
          closed: false,
        }
      Err(e) =>
        if self.fail_entry(entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
  }
  panic() // the last attempt either returns or raises
}

///|
/// Execute a statement on the dedicated connection and return its
/// result. Failures with `BadConn` discard the connection and are
/// retried on a fresh one.
pub async fn Conn::execute(
  self : Self,
  query : String,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> ExecResult {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match self.acquire_entry(attempt) {
      Some(entry) => entry
      None => continue
    }
    // Capture errors so the statement can be closed before the error
    // propagates.
    let result : Result[ExecResult, Error] = Ok(
      {
        let stmt = entry.conn.prepare(query)
        let executed : Result[ExecResult, Error] = Ok(exec_stmt(stmt, params)) catch {
          e => Err(e)
        }
        match executed {
          Err(e) => {
            stmt.close() catch {
              _ => ()
            }
            raise e
          }
          Ok(result) => {
            stmt.close()
            result
          }
        }
      },
    ) catch {
      e => Err(e)
    }
    match result {
      Ok(result) => return result
      Err(e) =>
        if self.fail_entry(entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
  }
  panic() // the last attempt either returns or raises
}

///|
/// Execute `script` verbatim on the dedicated connection — the text
/// may contain multiple statements; no parameters are bound. Failures
/// with `BadConn` discard the connection and are retried on a fresh
/// one; like `execute`, a retry is only possible when the script never
/// reached the server.
pub async fn Conn::execute_script(self : Self, script : String) -> Unit {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match self.acquire_entry(attempt) {
      Some(entry) => entry
      None => continue
    }
    let result : Result[Unit, Error] = Ok(entry.conn.execute_script(script)) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => return
      Err(e) =>
        if self.fail_entry(entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
  }
  panic() // the last attempt either returns or raises
}

///|
/// Execute a transaction on the dedicated connection and commit it if
/// no error occurs. Beginning the transaction is retried on `BadConn`;
/// once `f` runs the transaction may have produced side effects, so
/// errors from `f` or `commit` are never retried. The connection stays
/// checked out afterwards unless it died with `BadConn`.
pub async fn[T] Conn::with_transaction(
  self : Self,
  f : async (Transaction) -> T,
) -> T {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match self.acquire_entry(attempt) {
      Some(entry) => entry
      None => continue
    }
    let tx_result : Result[&@driver.Tx, Error] = Ok(entry.conn.begin()) catch {
      e => Err(e)
    }
    let tx = match tx_result {
      Ok(tx) => tx
      Err(e) =>
        if self.fail_entry(entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
    // The transaction has begun; do not retry past this point.
    let f_result : Result[T, Error] = Ok(f(Transaction::{ conn: entry, })) catch {
      e => Err(e)
    }
    let result = match f_result {
      Err(e) => {
        // Best-effort rollback; the error from `f` is the one reported.
        tx.rollback() catch {
          _ => ()
        }
        if e is @driver.BadConn(_) {
          self.pool.release(entry, bad=true)
          self.entry = None
        }
        raise e
      }
      Ok(result) => result
    }
    let commit_result : Result[Unit, Error] = Ok(tx.commit()) catch {
      e => Err(e)
    }
    match commit_result {
      Err(e) => {
        if e is @driver.BadConn(_) {
          self.pool.release(entry, bad=true)
          self.entry = None
        }
        raise e
      }
      Ok(_) => return result
    }
  }
  panic() // the last attempt either returns or raises
}

///|
/// Create a prepared statement bound to this connection. The statement
/// always runs on this dedicated connection; if the underlying
/// connection dies (`BadConn`), a fresh one is acquired lazily and the
/// statement re-prepared on it.
pub fn Conn::prepare(self : Self, query : String) -> Stmt raise {
  if self.closed {
    fail("use of closed connection")
  }
  Stmt::{
    query,
    pool: self.pool,
    bound: Some(self),
    closed: false,
    handles: {},
  }
}

///|
/// Return the checked-out entry, acquiring a fresh connection when the
/// previous one was discarded as `BadConn`. Returns `None` when
/// acquisition fails with `BadConn` and attempts remain, signaling the
/// caller to retry; any other error is raised.
async fn Conn::acquire_entry(self : Conn, attempt : Int32) -> ConnEntry? {
  if self.closed {
    fail("use of closed connection")
  }
  match self.entry {
    Some(entry) => Some(entry)
    None => {
      let result : Result[ConnEntry, Error] = Ok(self.pool.acquire()) catch {
        e => Err(e)
      }
      match result {
        Ok(entry) => {
          self.entry = Some(entry)
          Some(entry)
        }
        Err(e) =>
          if e is @driver.BadConn(_) && attempt < max_bad_conn_retries {
            None
          } else {
            raise e
          }
      }
    }
  }
}

///|
/// Discard `entry` when `e` is `BadConn`, so the next attempt (or the
/// next operation on this `Conn`) acquires a fresh connection. Returns
/// `true` when the operation may be retried.
async fn Conn::fail_entry(
  self : Conn,
  entry : ConnEntry,
  e : Error,
  attempt : Int32,
) -> Bool {
  if e is @driver.BadConn(_) {
    self.pool.release(entry, bad=true)
    self.entry = None
    attempt < max_bad_conn_retries
  } else {
    false
  }
}
