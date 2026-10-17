///|
/// Shared pool state, driven by `DBExecutor`. The package runs on the
/// single-threaded async runtime, so `mut` fields are coroutine-safe as
/// long as no mutation is left half-done across a suspension point.
priv struct Pool {
  connector : &@driver.Connector
  /// Capacity semaphore pre-filled with `max_open` tokens. A token is a
  /// checkout permit: it travels with the connection while it is checked
  /// out, being created, or waiting for `serve_closes` to close it, and
  /// goes back to the queue when the connection goes idle or finishes
  /// closing. Idle connections carry no token, so a free token always
  /// exists when a reusable connection does.
  slots : @aqueue.Queue[Unit]
  /// Requests to open a physical connection, served by the executor's
  /// `serve_creations` worker.
  create_requests : @aqueue.Queue[CreateRequest]
  /// Connections retired by `acquire`/`release`, closed by the
  /// executor's `serve_closes` worker.
  close_requests : @aqueue.Queue[ConnEntry]
  /// Idle connections available for reuse; bounded by `max_idle`.
  idle_connections : @aqueue.Queue[ConnEntry]
  /// Completed by `DBExecutor::run` once its workers are running, and by
  /// `Pool::close` so waiters never hang.
  ready : Completion
  /// Completed by `Pool::close`; `DBExecutor::run` waits on it before
  /// starting teardown.
  shutdown : Completion
  /// Completed by `DBExecutor::run` when it exits; `Pool::close` waits
  /// on it when the executor was started.
  done : Completion
  /// Whether `DBExecutor::run` was called.
  mut started : Bool
  /// Whether `Pool::close` was called.
  mut closed : Bool
  /// Total live connections managed by the pool (in_use + idle).
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
/// A request sent to `serve_creations` asking for a new physical
/// connection. The result is delivered on a one-slot queue: on success
/// the entry is `put` into it, on failure the queue is closed with the
/// connection error so `acquire` observes the driver's original error.
priv struct CreateRequest {
  result : @aqueue.Queue[ConnEntry]
}

///|
/// A one-shot latch for pool lifecycle transitions, modelled on pgpool's
/// `Completion`: `complete` wakes all current and future `wait`ers, and
/// completing twice is a no-op.
priv struct Completion {
  mut done : Bool
  signal : @aqueue.Queue[Unit]
}

///|
fn Completion::Completion() -> Completion {
  { done: false, signal: @aqueue.Queue(kind=Unbounded), }
}

///|
fn Completion::complete(self : Completion) -> Unit {
  if self.done {
    return
  }
  self.done = true
  self.signal.close()
}

///|
async fn Completion::wait(self : Completion) -> Unit {
  if !self.done {
    ignore(self.signal.get()) catch {
      @aqueue.QueueAlreadyClosed => ()
      e => raise e
    }
  }
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
  let slots : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Blocking(max_open))
  for _ in 0..<max_open {
    ignore(slots.try_put(())) catch {
      _ => ()
    }
  }
  {
    connector,
    slots,
    create_requests: @aqueue.Queue(kind=Unbounded),
    close_requests: @aqueue.Queue(kind=Unbounded),
    idle_connections: @aqueue.Queue(kind=Blocking(max_idle)),
    ready: Completion::Completion(),
    shutdown: Completion::Completion(),
    done: Completion::Completion(),
    started: false,
    closed: false,
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
/// Return one capacity token; a closed token queue swallows it, which is
/// fine since a closed pool no longer needs capacity accounting.
fn Pool::release_slot(self : Pool) -> Unit {
  ignore(self.slots.try_put(())) catch {
    _ => ()
  }
}

///|
/// Retire `entry`: hand it to the executor's `serve_closes` worker, which
/// closes it and returns the capacity token travelling with it. If the
/// worker is already gone the connection is closed inline and the token
/// freed directly.
async fn Pool::discard_entry(self : Pool, entry : ConnEntry) -> Unit {
  self.active_count -= 1
  let queued = self.close_requests.try_put(entry) catch { _ => false }
  if !queued {
    entry.close() catch {
      _ => ()
    }
    self.release_slot()
  }
}

///|
/// Close every idle connection and the idle queue itself.
async fn Pool::drain_idle(self : Pool) -> Unit {
  while (self.idle_connections.try_get() catch { _ => None }) is Some(entry) {
    self.active_count -= 1
    entry.close() catch {
      _ => ()
    }
  }
  self.idle_connections.close()
}

///|
/// Stop the pool: wake anyone waiting on `ready`/`shutdown`, unblock
/// acquirers parked on the capacity semaphore, then either wait for the
/// executor's teardown (`done`) or, when it was never started, clean up
/// inline. Idempotent.
async fn Pool::close(self : Pool) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.ready.complete()
  self.shutdown.complete()
  self.slots.close()
  if self.started {
    self.done.wait()
  } else {
    self.create_requests.close()
    self.close_requests.close()
    self.drain_idle()
  }
}

///|
/// Check out a connection. Reusable idle connections are preferred; when
/// none is available the executor's `serve_creations` worker opens a new
/// one. A capacity token is reserved before each attempt: it becomes the
/// checkout permit of the acquired connection, is consumed by a
/// discarded connection (which keeps it until `serve_closes` finishes
/// closing it), and is returned if the attempt fails.
async fn Pool::acquire(self : Pool) -> ConnEntry {
  // Wait for the executor so requests are actually served; acquisitions
  // made before `DBExecutor::run` starts queue up instead of hanging on
  // an unserved create request.
  self.ready.wait()
  for ;; {
    if (self.slots.try_get() catch { _ => None }) is None {
      // The pool is exhausted: block until a connection is released or
      // closed, recording the wait for `DB::stats`.
      let start = @env.now().reinterpret_as_int64()
      self.slots.get() catch {
        @aqueue.QueueAlreadyClosed => fail("connection pool is closed")
        e => raise e
      }
      self.wait_count += 1
      self.wait_duration_ms += @env.now().reinterpret_as_int64() - start
    }
    let idle = self.idle_connections.try_get() catch { _ => None }
    match idle {
      Some(entry) => {
        let now = @env.now().reinterpret_as_int64()
        // Expiry is lazy: there is no background reaper, so expired
        // connections are only discarded when encountered here or in
        // `release`.
        let lifetime_expired = self.max_lifetime_ms > 0 &&
          now - entry.created_at > self.max_lifetime_ms
        let idle_expired = entry.returned &&
          self.max_idle_time_ms > 0 &&
          now - entry.returned_at > self.max_idle_time_ms
        if lifetime_expired || idle_expired {
          // A connection expired on both counts is attributed to its
          // lifetime, matching Go's ordering of the checks.
          if lifetime_expired {
            self.max_lifetime_closed += 1
          } else {
            self.max_idle_time_closed += 1
          }
          self.discard_entry(entry)
          // The discarded connection consumed the token, which
          // `serve_closes` returns after closing it; take a fresh
          // token before retrying.
          continue
        }
        if !entry.conn.is_valid() {
          self.discard_entry(entry)
          continue
        }
        if entry.returned {
          entry.conn.reset_session() catch {
            _ => {
              self.discard_entry(entry)
              continue
            }
          }
        }
        self.in_use += 1
        return entry
      }
      None => {
        let request = CreateRequest::{
          result: @aqueue.Queue(kind=Blocking(1)),
        }
        // If the caller failed or was cancelled after the worker
        // already delivered an entry, retire it instead of leaking
        // the connection and its token; otherwise free the token.
        errdefer (if (request.result.try_get() catch { _ => None })
          is Some(entry) {
          self.discard_entry(entry)
        } else {
          self.release_slot()
        })
        self.create_requests.put(request) catch {
          @aqueue.QueueAlreadyClosed => fail("connection pool is closed")
          e => raise e
        }
        let entry = request.result.get()
        self.in_use += 1
        return entry
      }
    }
  }
  panic() // unreachable: the loop only exits via return or raise
}

///|
/// Serve connection creation requests on the executor's task group.
/// Each request is handled by its own background task so a slow
/// handshake does not block other creations; failures are reported to
/// the requester through the request's result queue. Exits when
/// `create_requests` is closed during teardown.
async fn serve_creations(pool : Pool, group : @async.TaskGroup[Unit]) -> Unit {
  for ;; {
    let request = pool.create_requests.get() catch {
      @aqueue.QueueAlreadyClosed => return
      e => raise e
    }
    group.spawn_bg(no_wait=true, allow_failure=true, () => {
      create_physical(pool, group, request)
    })
  }
}

///|
/// Open one physical connection for `request`: connect through the
/// driver, spawn the connection's executor on the pool's task group,
/// wait for the connection to become ready, then deliver the entry to
/// the requester. On any failure the requester's result queue is closed
/// with the original error.
async fn create_physical(
  pool : Pool,
  group : @async.TaskGroup[Unit],
  request : CreateRequest,
) -> Unit {
  let created : Result[ConnEntry, Error] = Ok(
    {
      let (conn, executor) = pool.connector.connect()
      group.spawn_bg(no_wait=true, allow_failure=true, () => executor.run())
      conn.ready()
      pool.new_entry(conn, @env.now().reinterpret_as_int64())
    },
  ) catch {
    e => Err(e)
  }
  match created {
    Err(e) => request.result.close(error=e)
    Ok(entry) => {
      pool.active_count += 1
      let delivered = !pool.closed &&
        (request.result.try_put(entry) catch { _ => false })
      if !delivered {
        // The pool closed mid-creation, or the requester went away:
        // retire the connection through the normal close path.
        pool.discard_entry(entry)
      }
    }
  }
}

///|
/// Serve connection close requests, closing each retired connection and
/// returning its capacity token afterwards. Exits when `close_requests`
/// is closed during teardown.
async fn serve_closes(pool : Pool) -> Unit {
  for ;; {
    let entry = pool.close_requests.get() catch {
      @aqueue.QueueAlreadyClosed => return
      e => raise e
    }
    @async.protect_from_cancel(() => entry.close() catch { _ => () })
    pool.release_slot()
  }
}

///|
/// Return a connection to the pool. Connections that are `bad`, past
/// their `max_lifetime`, overflow `max_idle`, or arrive after close are
/// retired through `close_requests`; healthy ones go back to the idle
/// queue and their capacity token is returned to the semaphore.
async fn Pool::release(
  self : Pool,
  entry : ConnEntry,
  bad~ : Bool = false,
) -> Unit {
  self.in_use -= 1
  let now = @env.now().reinterpret_as_int64()
  // A connection past its maximum lifetime is discarded through the same
  // path as a `bad` one.
  let lifetime_expired = self.max_lifetime_ms > 0 &&
    now - entry.created_at > self.max_lifetime_ms
  if bad || lifetime_expired || self.closed {
    if lifetime_expired {
      self.max_lifetime_closed += 1
    }
    self.discard_entry(entry)
    return
  }
  entry.returned = true
  entry.returned_at = now
  let queued = self.idle_connections.try_put(entry) catch { _ => false }
  if queued {
    // The idle connection no longer needs the checkout permit: return
    // the token so a blocked acquirer can pick the connection up.
    self.release_slot()
    return
  }
  // The idle queue is full (`max_idle`): the connection is closed.
  self.max_idle_closed += 1
  self.discard_entry(entry)
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
