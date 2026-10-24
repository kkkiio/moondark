///|
priv struct Scope {
  mut active : Bool
}

///|
fn Scope::check(self : Scope) -> Unit raise {
  if !self.active {
    raise DatabaseError::ScopeExpired
  }
}

///|
priv struct ClientState {
  entry : ConnEntry
  pool : Pool
  scope : Scope
  gate : @async.Mutex
  mut bad : Bool
  mut completed : Bool
  mut retry_safe : Bool
  mut active_stream : RowStream?
}

///|
async fn[T] scoped(
  scope : Scope,
  cleanup : async () -> Unit,
  f : async () -> T,
) -> T {
  let mut finalized = false
  errdefer (if !finalized {
    scope.active = false
    @async.protect_from_cancel(() => cleanup() catch { _ => () })
  })
  check_pending_cancellation()
  let result = f()
  check_pending_cancellation()
  scope.active = false
  finalized = true
  {
    defer check_pending_cancellation()
    @async.protect_from_cancel(cleanup)
  }
  result
}

///|
async fn[T] ClientState::operation(self : ClientState, f : async () -> T) -> T {
  self.scope.check()
  self.gate.acquire()
  defer self.gate.release()
  self.scope.check()
  if self.bad || self.completed {
    raise DatabaseError::Closed("connection")
  }
  errdefer (if !self.entry.conn.is_valid() { self.bad = true })
  f() catch {
    @driver.BadConn(_) as e => {
      self.bad = true
      raise e
    }
    e => raise e
  }
}

///|
async fn ClientState::statement(
  self : ClientState,
  sql : String,
) -> &@driver.Stmt {
  if self.entry.stmt_cache.get(sql) is Some(stmt) {
    self.entry.stmt_cache.remove(sql)
    self.entry.stmt_cache[sql] = stmt
    return stmt
  }
  let stmt = @async.protect_from_cancel(() => self.entry.conn.prepare(sql))
  if self.pool.statement_cache_capacity > 0 {
    self.entry.stmt_cache[sql] = stmt
    if self.entry.stmt_cache.length() > self.pool.statement_cache_capacity {
      if self.entry.stmt_cache.iter().next() is Some((key, evicted)) {
        self.entry.stmt_cache.remove(key)
        errdefer {
          self.bad = true
        }
        @async.protect_from_cancel(() => evicted.close())
      }
    }
  }
  stmt
}

///|
fn bind(stmt : &@driver.Stmt, params : ArrayView[&ToSql]) -> Array[Value] raise {
  let expected = stmt.num_input()
  if expected >= 0 && expected != params.length() {
    raise DatabaseError::ArityMismatch(expected~, actual=params.length())
  }
  params.map(p => p.to_sql())
}

///|
async fn[T] ClientState::with_statement(
  self : ClientState,
  sql : String,
  f : async (&@driver.Stmt) -> T,
) -> T {
  self.operation(() => {
    let stmt = self.statement(sql)
    let scope = Scope::{ active: true, }
    scoped(
      scope,
      () => {
        if self.pool.statement_cache_capacity == 0 {
          errdefer {
            self.bad = true
          }
          stmt.close()
        }
      },
      () => f(stmt),
    )
  })
}

///|
async fn check_pending_cancellation() -> Unit noraise {
  if @async.is_being_cancelled() {
    @async.pause()
  }
}
