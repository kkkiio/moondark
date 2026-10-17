///|
priv struct Pool {
  idle_connections : @aqueue.Queue[ConnEntry]
  connector : &@driver.Connector
  mut active_count : Int32
  /// Connections currently checked out of the pool.
  mut in_use : Int32
  max_open : Int32
  /// Maximum number of prepared statements cached per connection;
  /// `0` disables the limit (unbounded, as in Go).
  max_stmts_per_conn : Int32
  /// Id assigned to the next pooled connection entry.
  mut next_conn_id : Int64
  /// Maximum connection lifetime in milliseconds; `<= 0` disables it.
  max_lifetime_ms : Int64
  /// Maximum idle time in milliseconds; `<= 0` disables it.
  max_idle_time_ms : Int64
  /// Number of times an `acquire` had to block waiting for a connection.
  mut wait_count : Int64
  /// Cumulative time blocked waiting for a connection, in milliseconds.
  mut wait_duration_ms : Int64
  /// Connections closed because the idle queue was full.
  mut max_idle_closed : Int64
  /// Connections closed because they exceeded `max_idle_time`.
  mut max_idle_time_closed : Int64
  /// Connections closed because they exceeded `max_lifetime`.
  mut max_lifetime_closed : Int64
}

///|
/// Convert a `Duration` to milliseconds for internal storage. A positive
/// duration smaller than one millisecond is clamped to 1ms so that it
/// still enables expiry (`<= 0` means disabled); it effectively means
/// "expires after ~0ms".
fn duration_ms(d : @time.Duration) -> Int64 {
  let ms = d.to_nanoseconds() / 1_000_000
  if ms == 0 && d.to_nanoseconds() > 0 {
    1
  } else {
    ms
  }
}

///|
fn Pool::Pool(
  connector : &@driver.Connector,
  max_idle~ : Int32,
  max_open~ : Int32,
  max_lifetime~ : @time.Duration,
  max_idle_time~ : @time.Duration,
  max_stmts_per_conn~ : Int32,
) -> Pool {
  {
    idle_connections: @aqueue.Queue(kind=Blocking(max_idle)),
    connector,
    active_count: 0,
    in_use: 0,
    max_open,
    max_stmts_per_conn,
    next_conn_id: 1,
    max_lifetime_ms: duration_ms(max_lifetime),
    max_idle_time_ms: duration_ms(max_idle_time),
    wait_count: 0,
    wait_duration_ms: 0,
    max_idle_closed: 0,
    max_idle_time_closed: 0,
    max_lifetime_closed: 0,
  }
}

///|
/// Wrap a driver connection in a pooled entry, assigning it a unique id.
fn Pool::new_entry(
  self : Pool,
  conn : &@driver.Conn,
  created_at : Int64,
) -> ConnEntry {
  let id = self.next_conn_id
  self.next_conn_id += 1
  ConnEntry::{
    id,
    conn,
    returned: false,
    created_at,
    returned_at: 0,
    stmt_cache: {},
  }
}

///|
async fn Pool::close(self : Pool) -> Unit {
  while (self.idle_connections.try_get() catch { _ => None }) is Some(entry) {
    entry.close()
    self.active_count -= 1
  }
  self.idle_connections.close()
}

///|
async fn Pool::acquire(self : Pool) -> ConnEntry {
  for ;; {
    let entry = match self.idle_connections.try_get() {
      Some(entry) => entry
      None =>
        if self.active_count < self.max_open {
          self.active_count += 1
          errdefer {
            self.active_count -= 1
          }
          let conn = self.connector.connect()
          self.in_use += 1
          return self.new_entry(conn, @env.now().reinterpret_as_int64())
        } else {
          // The pool is exhausted: block until a connection is
          // released, recording the wait for `DB::stats`.
          let start = @env.now().reinterpret_as_int64()
          let entry = self.idle_connections.get()
          self.wait_count += 1
          self.wait_duration_ms += @env.now().reinterpret_as_int64() - start
          entry
        }
    }
    let now = @env.now().reinterpret_as_int64()
    // Expiry is lazy: there is no background reaper, so expired
    // connections are only discarded when encountered here or in
    // `release`. Freshly created connections skip this check (they
    // return above without touching the idle queue), as in Go.
    let lifetime_expired = self.max_lifetime_ms > 0 &&
      now - entry.created_at > self.max_lifetime_ms
    let idle_expired = entry.returned &&
      self.max_idle_time_ms > 0 &&
      now - entry.returned_at > self.max_idle_time_ms
    if lifetime_expired || idle_expired {
      entry.close() catch {
        _ => ()
      }
      self.active_count -= 1
      // A connection expired on both counts is attributed to its
      // lifetime, matching Go's ordering of the checks.
      if lifetime_expired {
        self.max_lifetime_closed += 1
      } else {
        self.max_idle_time_closed += 1
      }
      continue
    }
    if !entry.conn.is_valid() {
      entry.close() catch {
        _ => ()
      }
      self.active_count -= 1
      continue
    }
    if entry.returned {
      entry.conn.reset_session() catch {
        _ => {
          entry.close() catch {
            _ => ()
          }
          self.active_count -= 1
          continue
        }
      }
    }
    self.in_use += 1
    return entry
  }
}

///|
async fn Pool::release(
  self : Pool,
  entry : ConnEntry,
  bad~ : Bool = false,
) -> Unit {
  self.in_use -= 1
  let now = @env.now().reinterpret_as_int64()
  // A connection past its maximum lifetime is discarded through the same
  // path as a `bad` one: close it and eagerly open a replacement.
  let lifetime_expired = self.max_lifetime_ms > 0 &&
    now - entry.created_at > self.max_lifetime_ms
  if bad || lifetime_expired {
    if lifetime_expired {
      self.max_lifetime_closed += 1
    }
    self.active_count -= 1
    entry.close() catch {
      _ => ()
    }
    // Open a replacement so tasks blocked in `acquire` observe the freed
    // capacity instead of starving when connections die en masse
    // (e.g. a database outage where every conn raises `BadConn`).
    if self.active_count < self.max_open {
      self.active_count += 1
      let new_conn = self.connector.connect() catch {
        _ => {
          self.active_count -= 1
          return
        }
      }
      let queued = self.idle_connections.try_put(self.new_entry(new_conn, now)) catch {
        _ => false
      }
      if !queued {
        self.active_count -= 1
        new_conn.close() catch {
          _ => ()
        }
      }
    }
    return
  }
  entry.returned = true
  entry.returned_at = now
  let queued = self.idle_connections.try_put(entry) catch { _ => false }
  if queued {
    return
  }
  // The idle queue is full (`max_idle`): the connection is closed.
  self.active_count -= 1
  self.max_idle_closed += 1
  entry.close() catch {
    _ => ()
  }
}

///|
/// Maximum number of times an operation is retried after its connection
/// raises `BadConn` (2 retries, 3 attempts total, as in Go). Retrying is
/// only safe because `BadConn` guarantees the operation was never sent
/// to the server.
let max_bad_conn_retries : Int32 = 2

///|
/// Acquire a connection for attempt `attempt` of a retried operation.
/// Returns `None` when acquisition fails with `BadConn` and attempts
/// remain, signaling the caller to retry; any other error is raised.
async fn acquire_retry(pool : Pool, attempt : Int32) -> ConnEntry? {
  let result : Result[ConnEntry, Error] = Ok(pool.acquire()) catch {
    e => Err(e)
  }
  match result {
    Ok(entry) => Some(entry)
    Err(e) =>
      if e is @driver.BadConn(_) && attempt < max_bad_conn_retries {
        None
      } else {
        raise e
      }
  }
}

///|
/// Release `entry` after a failed operation, discarding it when `e` is
/// `BadConn`. Returns `true` when the error is a `BadConn` and attempts
/// remain, i.e. the operation may be retried on a fresh connection.
async fn release_failed(
  pool : Pool,
  entry : ConnEntry,
  e : Error,
  attempt : Int32,
) -> Bool {
  let bad = e is @driver.BadConn(_)
  pool.release(entry, bad~)
  bad && attempt < max_bad_conn_retries
}

///|
/// A connection managed by the pool: the queue element wrapping a
/// driver connection with its identity, bookkeeping timestamps and
/// per-connection prepared statement cache.
priv struct ConnEntry {
  /// Unique id assigned by the pool; keys `Stmt::handles`.
  id : Int64
  conn : &@driver.Conn
  /// Whether the connection was used before and returned to the pool.
  mut returned : Bool
  /// When the driver connection was opened, in milliseconds.
  created_at : Int64
  /// When the connection was last returned to the pool, in
  /// milliseconds; `0` while it has never been returned.
  mut returned_at : Int64
  /// Cached prepared statements on this connection, keyed by query
  /// text; insertion order is the LRU order (oldest first).
  stmt_cache : Map[String, ConnStmt]
}

///|
/// Close the driver connection and every statement cached on it,
/// unregistering each from its owning `Stmt`.
async fn ConnEntry::close(self : ConnEntry) -> Unit {
  for _, cs in self.stmt_cache {
    cs.stmt.close() catch {
      _ => ()
    }
    cs.owner.handles.remove(self.id)
  }
  self.stmt_cache.clear()
  self.conn.close()
}
