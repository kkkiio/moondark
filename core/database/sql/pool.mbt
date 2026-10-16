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
  if self.idle_connections.try_get() is Some(conn) {
    return conn
  }
  if self.active_count < self.max_open {
    self.active_count += 1
    errdefer {
      self.active_count -= 1
    }
    return Conn::{ conn: self.connector.connect(), }
  }
  self.idle_connections.get()
}

///|
async fn Pool::release(self : Pool, conn : Conn) -> Unit {
  let queued = self.idle_connections.try_put(conn) catch { _ => false }
  if queued {
    return
  }
  self.active_count -= 1
  conn.conn.close()
}
