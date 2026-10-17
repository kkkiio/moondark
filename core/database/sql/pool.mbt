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
