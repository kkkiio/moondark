///|
struct DB {
  pool : Pool
}

///|
struct DBExecutor {
  pool : Pool
}

///|
/// Create a connection pool and its background `DBExecutor`.
///
/// Spawn `executor.run()` on a task group that outlives the `DB`, then call `db.ready()`.
pub fn DB::create(
  connector : &@driver.Connector,
  max_idle~ : Int32 = 5,
  max_open~ : Int32 = 10,
  max_lifetime~ : @time.Duration = @time.Duration::zero(),
  max_idle_time~ : @time.Duration = @time.Duration::zero(),
  statement_cache_capacity~ : Int32 = 100,
) -> (DB, DBExecutor) {
  let max_open = if max_open <= 0 { 10 } else { max_open }
  let max_idle = if max_idle < 0 {
    0
  } else if max_idle > max_open {
    max_open
  } else {
    max_idle
  }
  let statement_cache_capacity = if statement_cache_capacity < 0 {
    0
  } else {
    statement_cache_capacity
  }
  let pool = Pool::Pool(
    connector,
    max_idle~,
    max_open~,
    max_lifetime~,
    max_idle_time~,
    statement_cache_capacity~,
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
    raise DatabaseError::ExecutorAlreadyStarted
  }
  pool.started = true
  defer pool.done.complete()
  defer @async.protect_from_cancel(() => {
    pool.closed = true
    pool.ready.complete()
    pool.shutdown.complete()
    pool.slots.close()
    for _, request in pool.pending {
      request.abandoned = true
      request.result.close(error=DatabaseError::Closed("DB"))
    }
    pool.create_requests.close()
    pool.close_requests.close()
    while (pool.create_requests.try_get() catch { _ => None }) is Some(request) {
      pool.release_slot()
      request.result.close(error=DatabaseError::Closed("DB"))
    }
    while (pool.close_requests.try_get() catch { _ => None }) is Some(entry) {
      entry.close() catch {
        _ => ()
      }
    }
    pool.drain_idle()
  })
  if pool.closed {
    pool.ready.complete()
    return
  }
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => serve_creations(pool, group))
    group.spawn_bg(no_wait=true, () => serve_closes(pool))
    pool.ready.complete()
    pool.shutdown.wait()
    pool.released.wait()
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
  @async.protect_from_cancel(() => self.pool.close())
}

///|
/// Return a snapshot of the pool's current and cumulative statistics.
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
async fn[T] DB::borrow(self : DB, f : async (Conn) -> T) -> T {
  let entry = self.pool.acquire()
  let scope = Scope::{ active: true, }
  let state = ClientState::{
    entry,
    pool: self.pool,
    scope,
    gate: @async.Mutex(),
    bad: false,
    completed: false,
    retry_safe: true,
    active_stream: None,
  }
  scoped(
    scope,
    () => {
      state.gate.acquire()
      defer state.gate.release()
      self.pool.release(entry, bad=state.bad || !entry.conn.is_valid())
    },
    () => f(Conn::{ state, }),
  )
}

///|
/// Borrow a dedicated `Conn` for the duration of `f` (session affinity),
/// resetting and returning it to the pool when `f` exits.
pub async fn[T] DB::with_conn(self : DB, f : async (Conn) -> T) -> T {
  self.borrow(f)
}

///|
async fn[T] DB::retry(self : DB, f : async (Conn) -> T) -> T {
  for attempt in 0..<=max_bad_conn_retries {
    let mut safe = true
    try
      self.borrow(conn => {
        errdefer {
          safe = conn.state.retry_safe
        }
        let result = f(conn)
        safe = false
        result
      })
    catch {
      @driver.BadConn(_) as e => {
        if !safe || attempt == max_bad_conn_retries {
          raise e
        }
        @xlog.warn(category="moondark.database") <?
          {
            "error": e.to_string(),
            "attempt": attempt + 1,
            "message": "BadConn, retrying operation on a fresh connection",
          }
        continue
      }
      e => raise e
    } noraise {
      result => return result
    }
  }
  panic()
}

///|
/// Run `f` inside a database transaction, committing on normal return and
/// rolling back under cancellation protection if `f` raises or is cancelled.
pub async fn[T] DB::with_transaction(
  self : DB,
  f : async (Transaction) -> T,
) -> T {
  for attempt in 0..<=max_bad_conn_retries {
    let mut entered = false
    try
      self.borrow(conn => {
        conn.with_transaction(tx => {
          entered = true
          f(tx)
        })
      })
    catch {
      @driver.BadConn(_) as e => {
        if entered || attempt == max_bad_conn_retries {
          raise e
        }
        @xlog.warn(category="moondark.database") <?
          {
            "error": e.to_string(),
            "attempt": attempt + 1,
            "message": "BadConn, retrying transaction startup on a fresh connection",
          }
        continue
      }
      e => raise e
    } noraise {
      result => return result
    }
  }
  panic()
}

///|
/// Stream rows from `sql` within `f`, draining and releasing the connection on exit.
pub async fn[T] DB::with_stream(
  self : DB,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
  f : async (RowStream) -> T,
) -> T {
  for attempt in 0..<=max_bad_conn_retries {
    let mut entered = false
    try
      self.borrow(conn => {
        conn.with_stream(sql, params~, stream => {
          entered = true
          f(stream)
        })
      })
    catch {
      @driver.BadConn(_) as e => {
        if entered || attempt == max_bad_conn_retries {
          raise e
        }
        @xlog.warn(category="moondark.database") <?
          {
            "error": e.to_string(),
            "attempt": attempt + 1,
            "message": "BadConn, retrying stream startup on a fresh connection",
          }
        continue
      }
      e => raise e
    } noraise {
      result => return result
    }
  }
  panic()
}

///|
/// Execute a statement on a pooled connection and return its `ExecResult`.
pub async fn DB::execute(
  self : DB,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
) -> ExecResult {
  self.retry(conn => conn.execute(sql, params~))
}

///|
/// Verify connectivity to the database, retrying on `BadConn`.
pub async fn DB::ping(self : DB) -> Unit {
  self.retry(conn => conn.ping())
}

///|
/// Execute a parameterless multi-statement SQL script on a pooled connection.
pub async fn DB::batch_execute(self : DB, sql : String) -> Unit {
  self.retry(conn => conn.batch_execute(sql))
}

///|
/// Execute `sql` on a pooled connection, collect all rows, and release the connection.
pub async fn DB::query_all(
  self : DB,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
) -> Array[Row] {
  self.retry(conn => conn.query_all(sql, params~))
}

///|
/// Execute `sql` on a pooled connection and return exactly one row.
/// Raises `DatabaseError::RowCount` if the query returns 0 or more than 1 row.
pub async fn DB::query_one(
  self : DB,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
) -> Row {
  self.retry(conn => conn.query_one(sql, params~))
}

///|
/// Execute `sql` on a pooled connection and return zero or one row.
/// Raises `DatabaseError::RowCount` if the query returns more than 1 row.
pub async fn DB::query_opt(
  self : DB,
  sql : String,
  params~ : ArrayView[&ToSql] = [],
) -> Row? {
  self.retry(conn => conn.query_opt(sql, params~))
}

///|
pub impl GenericClient for DB with fn query_all(self, sql, params?) {
  self.query_all(sql, params?)
}

///|
pub impl GenericClient for DB with fn query_one(self, sql, params?) {
  self.query_one(sql, params?)
}

///|
pub impl GenericClient for DB with fn query_opt(self, sql, params?) {
  self.query_opt(sql, params?)
}

///|
pub impl GenericClient for DB with fn execute(self, sql, params?) {
  self.execute(sql, params?)
}

///|
pub impl GenericClient for DB with fn ping(self) {
  self.ping()
}

///|
pub impl GenericClient for DB with fn batch_execute(self, sql) {
  self.batch_execute(sql)
}
