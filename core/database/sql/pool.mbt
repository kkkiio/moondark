///|
priv struct Pool {
  idle_connections : @aqueue.Queue[Conn]
  connector : &@driver.Connector
  mut active_count : Int32
  max_open : Int32
  /// Maximum connection lifetime in milliseconds; `<= 0` disables it.
  max_lifetime_ms : Int64
  /// Maximum idle time in milliseconds; `<= 0` disables it.
  max_idle_time_ms : Int64
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
    max_open,
    max_lifetime_ms: duration_ms(max_lifetime),
    max_idle_time_ms: duration_ms(max_idle_time),
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
          return Conn::{
            conn: self.connector.connect(),
            returned: false,
            created_at: @env.now().reinterpret_as_int64(),
            returned_at: 0,
          }
        } else {
          self.idle_connections.get()
        }
    }
    let now = @env.now().reinterpret_as_int64()
    // Expiry is lazy: there is no background reaper, so expired
    // connections are only discarded when encountered here or in
    // `release`. Freshly created connections skip this check (they
    // return above without touching the idle queue), as in Go.
    if (
        self.max_lifetime_ms > 0 && now - conn.created_at > self.max_lifetime_ms
      ) ||
      (
        conn.returned &&
        self.max_idle_time_ms > 0 &&
        now - conn.returned_at > self.max_idle_time_ms
      ) {
      conn.conn.close() catch {
        _ => ()
      }
      self.active_count -= 1
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
    return conn
  }
}

///|
async fn Pool::release(self : Pool, conn : Conn, bad~ : Bool = false) -> Unit {
  let now = @env.now().reinterpret_as_int64()
  // A connection past its maximum lifetime is discarded through the same
  // path as a `bad` one: close it and eagerly open a replacement.
  if bad ||
    (self.max_lifetime_ms > 0 && now - conn.created_at > self.max_lifetime_ms) {
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
  self.active_count -= 1
  conn.conn.close() catch {
    _ => ()
  }
}
