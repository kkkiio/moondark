///|
priv struct Pool {
  idle_connections : @aqueue.Queue[Conn]
  connector : &@driver.Connector
  mut active_count : Int32
  max_open : Int32
}

///|
fn Pool::Pool(
  connector : &@driver.Connector,
  max_idle~ : Int32,
  max_open~ : Int32,
) -> Pool {
  {
    idle_connections: @aqueue.Queue(kind=Blocking(max_idle)),
    connector,
    active_count: 0,
    max_open,
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
          return Conn::{ conn: self.connector.connect(), returned: false, }
        } else {
          self.idle_connections.get()
        }
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
  if bad {
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
  let queued = self.idle_connections.try_put(conn) catch { _ => false }
  if queued {
    return
  }
  self.active_count -= 1
  conn.conn.close() catch {
    _ => ()
  }
}
