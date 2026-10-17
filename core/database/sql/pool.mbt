///|
priv struct Pool {
  idle_connections : @aqueue.Queue[Conn]
  connector : &@driver.Connector
  mut active_count : Int32
  /// Connections currently checked out of the pool.
  mut in_use : Int32
  max_open : Int32
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
) -> Pool {
  {
    idle_connections: @aqueue.Queue(kind=Blocking(max_idle)),
    connector,
    active_count: 0,
    in_use: 0,
    max_open,
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
async fn Pool::close(self : Pool) -> Unit {
  while (self.idle_connections.try_get() catch { _ => None }) is Some(conn) {
    conn.conn.close()
    self.active_count -= 1
  }
  self.idle_connections.close()
}

///|
async fn Pool::acquire(self : Pool) -> Conn {
  for ;; {
    let conn = match self.idle_connections.try_get() {
      Some(conn) => conn
      None =>
        if self.active_count < self.max_open {
          self.active_count += 1
          errdefer {
            self.active_count -= 1
          }
          let conn = self.connector.connect()
          self.in_use += 1
          return Conn::{
            conn,
            returned: false,
            created_at: @env.now().reinterpret_as_int64(),
            returned_at: 0,
          }
        } else {
          // The pool is exhausted: block until a connection is
          // released, recording the wait for `DB::stats`.
          let start = @env.now().reinterpret_as_int64()
          let conn = self.idle_connections.get()
          self.wait_count += 1
          self.wait_duration_ms += @env.now().reinterpret_as_int64() - start
          conn
        }
    }
    let now = @env.now().reinterpret_as_int64()
    // Expiry is lazy: there is no background reaper, so expired
    // connections are only discarded when encountered here or in
    // `release`. Freshly created connections skip this check (they
    // return above without touching the idle queue), as in Go.
    let lifetime_expired = self.max_lifetime_ms > 0 &&
      now - conn.created_at > self.max_lifetime_ms
    let idle_expired = conn.returned &&
      self.max_idle_time_ms > 0 &&
      now - conn.returned_at > self.max_idle_time_ms
    if lifetime_expired || idle_expired {
      conn.conn.close() catch {
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
    if !conn.conn.is_valid() {
      conn.conn.close() catch {
        _ => ()
      }
      self.active_count -= 1
      continue
    }
    if conn.returned {
      conn.conn.reset_session() catch {
        _ => {
          conn.conn.close() catch {
            _ => ()
          }
          self.active_count -= 1
          continue
        }
      }
    }
    self.in_use += 1
    return conn
  }
}

///|
async fn Pool::release(self : Pool, conn : Conn, bad~ : Bool = false) -> Unit {
  self.in_use -= 1
  let now = @env.now().reinterpret_as_int64()
  // A connection past its maximum lifetime is discarded through the same
  // path as a `bad` one: close it and eagerly open a replacement.
  let lifetime_expired = self.max_lifetime_ms > 0 &&
    now - conn.created_at > self.max_lifetime_ms
  if bad || lifetime_expired {
    if lifetime_expired {
      self.max_lifetime_closed += 1
    }
    self.active_count -= 1
    conn.conn.close() catch {
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
      let queued = self.idle_connections.try_put(Conn::{
        conn: new_conn,
        returned: false,
        created_at: now,
        returned_at: 0,
      }) catch {
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
  conn.returned = true
  conn.returned_at = now
  let queued = self.idle_connections.try_put(conn) catch { _ => false }
  if queued {
    return
  }
  // The idle queue is full (`max_idle`): the connection is closed.
  self.active_count -= 1
  self.max_idle_closed += 1
  conn.conn.close() catch {
    _ => ()
  }
}
