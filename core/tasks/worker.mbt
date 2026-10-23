///|
/// The storage half a DB-backed `DBTaskBackend` implements so a
/// `Worker` can execute tasks — the queue-store operations of the
/// worker protocol (claim → run → save).
pub(open) trait TaskStore {
  /// Atomically claim the next runnable task for `worker_id`: pick
  /// the `Ready` row with the earliest `enqueued_at` whose `run_after`
  /// is unset or `<= now`, and transition it to `Running` —
  /// incrementing `attempts`, setting `started_at`, and appending
  /// `worker_id` to `worker_ids`. Returns the claimed `TaskResult`,
  /// or `None` when nothing is runnable.
  ///
  /// `Running` rows whose `started_at <= stale_before` are considered
  /// abandoned by a dead worker and are claimed too (filtered by the
  /// row's `max_attempts` budget). Pass `None` to never reclaim, for
  /// at-most-once delivery.
  async fn claim(
    Self,
    worker_id~ : String,
    now~ : Int64,
    stale_before~ : Int64?,
  ) -> TaskResult?
  /// Persist `result` as the row's new state: a terminal
  /// `Successful`/`Failed`, or a `Ready` reschedule for a retry. Only
  /// update a Running row whose attempts and worker_ids still match;
  /// silently ignore completion from an attempt that was reclaimed.
  async fn save(Self, result : TaskResult) -> Unit
}

///|
/// A polling worker that claims tasks from a `TaskStore` and runs them
/// outside the request-response cycle.
///
/// `tasks` is the registry resolving `TaskResult.task_name` back to a
/// `TaskExec`; workers and producers can run in the same process or
/// different ones — only the table is shared.
pub struct Worker {
  store : &TaskStore
  tasks : Map[String, TaskExec]
  /// identifier recorded in `TaskResult.worker_ids` on each claim.
  id : String
  /// sleep between polls when the queue is empty, in ms.
  poll_interval : Int32
  /// attempt number -> delay before the next attempt, in ms.
  backoff : (Int32) -> Int64
  /// `Running` rows idle longer than this many ms are reclaimed for
  /// re-execution — they belong to a worker that died mid-task.
  /// `None` never reclaims: at-most-once delivery.
  reclaim_after : Int64?
  /// A store outage longer than this many ms escalates from `warn`
  /// to one `error` log and makes `is_healthy` false — the window a
  /// `/healthz` probe should use.
  unhealthy_after : Int64
  /// ms timestamp of the last successful store round-trip; doubles as
  /// the worker heartbeat for liveness probes.
  mut last_success : Int64
  /// Whether the current outage already emitted its `error` entry.
  mut unhealthy_logged : Bool
  now : () -> Int64
}

///|
/// Default retry backoff: `min(1s * 2^(attempt-1), 10min)` in ms —
/// 1s, 2s, 4s, ..., capped at 600000.
pub fn default_backoff(attempt : Int32) -> Int64 {
  let ms = if attempt > 10 { 600_000L } else { 1000L << (attempt - 1) }
  if ms > 600_000L {
    600_000L
  } else {
    ms
  }
}

///|
/// The worker-side half of a task: its name plus the function to run.
/// Retry policy is not stored here — it lives on the task row, as
/// snapshotted by `TransactionalTaskDef` at enqueue time.
pub struct TaskExec {
  name : String
  func : async (TaskContext, Json) -> Json
}

///|
/// Build a `TaskExec` for `def` out of a typed function. `args` are
/// decoded through `T : FromJson`; a row whose serialized args fail
/// to decode fails the attempt like any other error.
pub fn[T : FromJson] TaskExec::from_def(
  def : TransactionalTaskDef[T],
  func~ : async (TaskContext, T) -> Json,
) -> TaskExec {
  TaskExec::{
    name: def.name,
    func: (ctx, args) => func(ctx, @json.from_json(args)),
  }
}

///|
/// Create a worker. `tasks` maps task names to definitions; a claimed
/// result whose `task_name` is missing is marked `Failed`.
pub fn Worker::new(
  store~ : &TaskStore,
  tasks~ : Array[TaskExec],
  id~ : String = "",
  poll_interval~ : Int32 = 200,
  backoff~ : (Int32) -> Int64 = default_backoff,
  reclaim_after~ : Int64? = Some(300_000),
  unhealthy_after~ : Int64 = 60_000,
  now~ : () -> Int64 = () => @env.now().reinterpret_as_int64(),
) -> Worker {
  Worker::{
    store,
    tasks: Map::from_iter(tasks.iter().map(task => (task.name, task))),
    id: if id.is_empty() {
      "worker-\{task_id()}"
    } else {
      id
    },
    poll_interval,
    backoff,
    reclaim_after,
    unhealthy_after,
    last_success: now(),
    unhealthy_logged: false,
    now,
  }
}

///|
/// ms timestamp of the last successful store round-trip — wire it into
/// a `/healthz` probe so a stuck worker is visible to k8s.
pub fn Worker::last_heartbeat(self : Self) -> Int64 {
  self.last_success
}

///|
/// Whether the store has answered within `unhealthy_after`. `false`
/// means the worker is alive but blind: it keeps retrying with
/// backoff, yet the queue is effectively stalled.
pub fn Worker::is_healthy(self : Self) -> Bool {
  (self.now)() - self.last_success <= self.unhealthy_after
}

///|
/// Claim and execute a single task. Returns `false` when nothing was
/// runnable. This is the unit `run` loops over, and is useful for
/// batch-mode drivers and tests.
///
/// On failure the result is rescheduled to `Ready` at
/// `now + backoff(attempt)` while the attempt count is within the
/// row's `max_attempts`, and marked `Failed` once the budget is spent.
pub async fn Worker::run_once(self : Self) -> Bool {
  let now = (self.now)()
  guard self.store.claim(
      worker_id=self.id,
      now~,
      stale_before=self.reclaim_after.map(d => now - d),
    )
    is Some(result) else {
    return false
  }
  guard self.tasks.get(result.task_name) is Some(task) else {
    @xlog.warn(category="moondark.tasks") <?
      {
        "message": "unknown task claimed, marking failed",
        "task": result.task_name,
        "worker": self.id,
      }
    self.store.save(TaskResult::{
      ..result,
      status: Failed,
      finished_at: Some((self.now)()),
      errors: [
        ..result.errors,
        TaskError::{
          exception: "tasks: unknown task '\{result.task_name}'",
          traceback: "",
        },
      ],
    })
    return true
  }
  let context = TaskContext::{ task_result: result, attempt: result.attempts, }
  let outcome : Result[Json, Error] = Ok((task.func)(context, result.args)) catch {
    e => Err(e)
  }
  let finished = match outcome {
    Ok(value) =>
      TaskResult::{
        ..result,
        status: Successful,
        return_value: Some(value),
        finished_at: Some((self.now)()),
      }
    Err(e) => {
      @xlog.warn(category="moondark.tasks") <?
        {
          "error": e.to_string(),
          "task": result.task_name,
          "attempt": result.attempts,
          "worker": self.id,
        }
      let errors = [
        ..result.errors,
        TaskError::{ exception: e.to_string(), traceback: "", },
      ]
      if result.attempts < result.max_attempts {
        TaskResult::{
          ..result,
          status: Ready,
          started_at: None,
          run_after: Some((self.now)() + (self.backoff)(result.attempts)),
          errors,
        }
      } else {
        TaskResult::{
          ..result,
          status: Failed,
          finished_at: Some((self.now)()),
          errors,
        }
      }
    }
  }
  let saved : Result[Unit, Error] = Ok(self.store.save(finished)) catch {
    e => Err(e)
  }
  // The task may have already run to completion — the row stays
  // Running until the stale-claim reaper re-executes it, which is
  // why this is `error` and mentions re-execution explicitly.
  if saved is Err(e) {
    @xlog.error(category="moondark.tasks") <?
      {
        "message": "save failed after task executed; it may run again",
        "error": e.to_string(),
        "task": result.task_name,
        "worker": self.id,
      }
    raise e
  }
  true
}

///|
/// Poll-execute loop: drain the queue, sleep `poll_interval`, repeat.
/// Runs until cancelled — spawn it on a task group and cancel the
/// group (or the task) to stop it:
///
/// ```moonbit nocheck
/// group.spawn_bg(no_wait=true, () => worker.run())
/// ```
///
/// Store failures (`claim`/`save` raising) do **not** kill the worker:
/// it warns, backs off exponentially (capped at 30s), and keeps
/// polling — a blip must not become a dead queue. A sustained outage
/// past `unhealthy_after` emits one `error` and flips `is_healthy`,
/// which is the signal a `/healthz` probe should report; recovery is
/// logged at `info`.
pub async fn Worker::run(self : Self) -> Unit {
  let mut failures = 0
  while true {
    let outcome : Result[Bool, Error] = Ok(self.run_once()) catch {
      e => Err(e)
    }
    match outcome {
      Ok(ran) => {
        self.last_success = (self.now)()
        if failures > 0 {
          if self.unhealthy_logged {
            @xlog.info(category="moondark.tasks") <?
              {
                "message": "task store recovered",
                "worker": self.id,
                "consecutive_failures": failures,
              }
          }
          failures = 0
          self.unhealthy_logged = false
        }
        if !ran {
          @async.sleep(self.poll_interval)
        }
      }
      Err(e) => {
        failures += 1
        @xlog.warn(category="moondark.tasks") <?
          {
            "error": e.to_string(),
            "worker": self.id,
            "consecutive_failures": failures,
          }
        if !self.unhealthy_logged &&
          (self.now)() - self.last_success > self.unhealthy_after {
          self.unhealthy_logged = true
          @xlog.error(category="moondark.tasks") <?
            {
              "message": "task store unavailable",
              "error": e.to_string(),
              "worker": self.id,
              "last_success": self.last_success,
            }
        }
        let shift = if failures > 8 { 8 } else { failures }
        let delay = self.poll_interval.to_int64() * (1L << shift)
        @async.sleep(if delay > 30_000L { 30_000 } else { delay.to_int() })
      }
    }
  }
}
