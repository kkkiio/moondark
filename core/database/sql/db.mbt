///|
/// Database with connection pool
struct DB {
  pool : Pool
}

///|
/// The background supervisor driving the pool's workers. `DB::create`
/// returns it alongside the `DB`; spawn it on a task group that outlives
/// the database, e.g. `group.spawn_bg(no_wait=true, () => executor.run())`.
pub struct DBExecutor {
  priv pool : Pool
}

///|
pub type ExecResult = @driver.ExecResult

///|
pub type Value = @driver.Value

///|
/// Snapshot of connection pool statistics, mirroring `sql.DBStats` in Go.
pub struct DBStats {
  /// Maximum number of open connections (`max_open`).
  max_open : Int32
  /// Total connections managed by the pool (in_use + idle).
  open : Int32
  /// Connections currently checked out.
  in_use : Int32
  /// Connections idle in the pool (open - in_use).
  idle : Int32
  /// Total number of times a caller had to block waiting for a connection.
  wait_count : Int64
  /// Cumulative time blocked waiting for a connection, in milliseconds.
  wait_duration_ms : Int64
  /// Connections closed because the idle queue was full (max_idle).
  max_idle_closed : Int64
  /// Connections closed because they exceeded max_idle_time.
  max_idle_time_closed : Int64
  /// Connections closed because they exceeded max_lifetime.
  max_lifetime_closed : Int64
} derive(Debug)

///|
pub extend DBStats with Debug::{to_repr}

///|
/// `max_lifetime` bounds how long a connection may live: connections
/// older than it are closed instead of being reused or returned to the
/// pool. `max_idle_time` bounds how long a connection may sit idle in
/// the pool. `Duration::zero()` (the default) disables each limit.
/// Expiry is lazy: expired connections are discarded when encountered
/// while acquiring from or releasing to the pool; there is no
/// background reaper.
///
/// `max_stmts_per_conn` bounds the number of prepared statements cached
/// on each pooled connection (see `DB::prepare`); `0` (the default)
/// disables the limit, matching Go.
///
/// Returns the `DB` and its `DBExecutor`. Creating them only allocates
/// shared state: no connection is opened until the executor is running.
/// Spawn the executor on a task group that outlives the `DB`:
///
/// ```
/// let (db, executor) = @sql.DB::create(connector)
/// group.spawn_bg(no_wait=true, () => executor.run())
/// db.ready()
/// ```
pub fn DB::create(
  connector : &@driver.Connector,
  max_idle~ : Int32 = 5,
  max_open~ : Int32 = 10,
  max_lifetime~ : @time.Duration = @time.Duration::zero(),
  max_idle_time~ : @time.Duration = @time.Duration::zero(),
  max_stmts_per_conn~ : Int32 = 0,
) -> (DB, DBExecutor) {
  let pool = Pool::Pool(
    connector,
    max_idle~,
    max_open~,
    max_lifetime~,
    max_idle_time~,
    max_stmts_per_conn~,
  )
  ({ pool, }, { pool, })
}

///|
/// Run the pool's workers until `DB::close`: one worker serves
/// connection-creation requests (spawning each physical connection's
/// `ConnExecutor` on the same task group), another serves close
/// requests. Calling `run` more than once raises an error.
pub async fn DBExecutor::run(self : DBExecutor) -> Unit {
  let pool = self.pool
  if pool.started {
    fail("DBExecutor::run called more than once")
  }
  pool.started = true
  defer pool.done.complete()
  if pool.closed {
    pool.ready.complete()
    return
  }
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => serve_creations(pool, group))
    group.spawn_bg(no_wait=true, () => serve_closes(pool))
    pool.ready.complete()
    pool.shutdown.wait()
    // Teardown: stop the workers by closing their request queues, reject
    // pending creations, and close everything still reachable.
    pool.create_requests.close()
    pool.close_requests.close()
    while (pool.create_requests.try_get() catch { _ => None }) is Some(request) {
      request.result.close()
    }
    while (pool.close_requests.try_get() catch { _ => None }) is Some(entry) {
      entry.close() catch {
        _ => ()
      }
    }
    pool.drain_idle()
  })
}

///|
/// Wait until the pool's background workers are running. This is not a
/// database connectivity check: it only reports that `DBExecutor::run`
/// has started serving requests.
pub async fn DB::ready(self : DB) -> Unit {
  self.pool.ready.wait()
}

///|
/// Close the database connection pool. Returns once the executor has
/// finished closing every pooled connection; if the executor was never
/// started, connections are closed inline instead of waiting.
pub async fn DB::close(self : DB) -> Unit {
  self.pool.close()
}

///|
/// Check out a dedicated connection from the pool, mirroring
/// `sql.DB.Conn` in Go. The returned `Conn` is not shared until
/// `Conn::close` returns it to the pool.
pub async fn DB::conn(self : Self) -> Conn {
  Conn::{ pool: self.pool, entry: Some(self.pool.acquire()), closed: false, }
}

///|
/// Create a prepared statement that runs on pooled connections. Like
/// `sql.Stmt` in Go, the physical driver statement is cached per
/// connection and re-prepared lazily on each new connection; the
/// per-connection cache is bounded by `max_stmts_per_conn`.
pub fn DB::prepare(self : Self, query : String) -> Stmt {
  Stmt::{ query, pool: self.pool, bound: None, closed: false, handles: {}, }
}

///|
/// Return a snapshot of the connection pool's statistics. Counters like
/// `wait_count` are cumulative since the `DB` was created; gauges like
/// `open`, `in_use` and `idle` reflect the current state.
pub fn DB::stats(self : DB) -> DBStats {
  {
    max_open: self.pool.max_open,
    open: self.pool.active_count,
    in_use: self.pool.in_use,
    idle: self.pool.active_count - self.pool.in_use,
    wait_count: self.pool.wait_count,
    wait_duration_ms: self.pool.wait_duration_ms,
    max_idle_closed: self.pool.max_idle_closed,
    max_idle_time_closed: self.pool.max_idle_time_closed,
    max_lifetime_closed: self.pool.max_lifetime_closed,
  }
}

///|
/// Run `query` and return its result rows; the connection stays checked
/// out until `Rows::close` returns it to the pool. Failures with
/// `BadConn` are retried on a fresh connection.
pub async fn DB::query(
  self : Self,
  query : String,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> Rows {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match acquire_retry(self.pool, attempt) {
      Some(entry) => entry
      None => continue
    }
    // Capture errors so the statement and connection can be released
    // before the error propagates.
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
          // Close the statement even on failure so driver resources are
          // not leaked; the original error is the one that propagates.
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
        // Success: the connection is released later by `Rows::close`.
        return Rows::{
          conn: entry,
          stmt,
          rows,
          pool: Some(self.pool),
          close_stmt: true,
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

///|
/// Execute a statement and return its result. Failures with `BadConn`
/// are retried on a fresh connection.
pub async fn DB::execute(
  self : Self,
  query : String,
  params~ : ArrayView[&@driver.Valuer] = [],
) -> ExecResult {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match acquire_retry(self.pool, attempt) {
      Some(entry) => entry
      None => continue
    }
    // Capture errors so the statement and connection can be released
    // before the error propagates.
    let result : Result[ExecResult, Error] = Ok(
      {
        let stmt = entry.conn.prepare(query)
        let executed : Result[ExecResult, Error] = Ok(exec_stmt(stmt, params)) catch {
          e => Err(e)
        }
        match executed {
          // Close the statement even on failure so driver resources are
          // not leaked; the original error is the one that propagates.
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

///|
/// Verify a connection to the database is still alive, establishing one
/// if necessary. Connections failing `ping` with `BadConn` are discarded
/// and the ping is retried on a fresh connection.
pub async fn DB::ping(self : Self) -> Unit {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match acquire_retry(self.pool, attempt) {
      Some(entry) => entry
      None => continue
    }
    let result : Result[Unit, Error] = Ok(entry.conn.ping()) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => {
        self.pool.release(entry)
        return
      }
      Err(e) =>
        if release_failed(self.pool, entry, e, attempt) {
          continue
        } else {
          raise e
        }
    }
  }
}

///|
/// Execute a transaction and commit it if no error occurs. Acquiring a
/// connection and beginning the transaction are retried on `BadConn`;
/// once `f` runs the transaction may have produced side effects, so
/// errors from `f` or `commit` are never retried.
pub async fn[T] DB::with_transaction(
  self : Self,
  f : async (Transaction) -> T,
) -> T {
  for attempt in 0..<=max_bad_conn_retries {
    let entry = match acquire_retry(self.pool, attempt) {
      Some(entry) => entry
      None => continue
    }
    let tx_result : Result[&@driver.Tx, Error] = Ok(entry.conn.begin()) catch {
      e => Err(e)
    }
    let tx = match tx_result {
      Ok(tx) => tx
      Err(e) =>
        if release_failed(self.pool, entry, e, attempt) {
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
        self.pool.release(entry, bad=e is @driver.BadConn(_))
        raise e
      }
      Ok(result) => result
    }
    let commit_result : Result[Unit, Error] = Ok(tx.commit()) catch {
      e => Err(e)
    }
    match commit_result {
      Err(e) => {
        self.pool.release(entry, bad=e is @driver.BadConn(_))
        raise e
      }
      Ok(_) => {
        self.pool.release(entry)
        return result
      }
    }
  }
  panic() // the last attempt either returns or raises
}
