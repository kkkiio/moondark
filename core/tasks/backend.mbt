///|
/// The contract between `Task` and a database-backed
/// queue store. `enqueue` inserts one task row into the caller's
/// transaction — the task commits atomically with the transaction's
/// other writes, which is the basis of at-least-once delivery.
/// `get_result` reads a stored row back by task name and id.
///
/// DB backends additionally implement `TaskStore`, which `Worker`
/// polls to actually run tasks.
pub(open) trait DBTaskBackend {
  /// Insert one `Ready` task row into `tx`, returning its id.
  async fn enqueue(
    Self,
    tx : @database.Transaction,
    task : TaskArgs,
    args : Json,
  ) -> String
  /// Fetch a stored result row by task name and id; `None` when the
  /// row does not exist.
  async fn get_result(Self, task_name : String, id : String) -> TaskResult?
}

///|
/// The enqueue-time fields of a task row, as `DBTaskBackend::enqueue`
/// receives them: everything the store needs that isn't the id or
/// the serialized `args`.
pub(all) struct TaskArgs {
  /// unique name used by workers to resolve the row back to a
  /// `TaskHandler`.
  name : String
  /// unix timestamp in ms; `None` runs as soon as a worker claims it.
  run_after : Int64?
  /// claim budget: total attempts allowed, counting the first (>= 1).
  max_attempts : Int32
}

///|
/// An in-memory task store: `enqueue` records a `Ready` row and
/// `Worker` can actually claim and run tasks from it — Django's
/// `DummyBackend` grown into a usable single-process queue.
///
/// `tx` is accepted but ignored: nothing is written to any database,
/// so there is no real atomicity with the transaction's other
/// writes. For development, tests and executable examples.
pub struct DummyBackend {
  results : Array[TaskResult]
  now : () -> Int64
}

///|
/// `now` defaults to wall-clock epoch ms; inject it in tests for
/// deterministic timestamps.
pub fn DummyBackend::new(
  now~ : () -> Int64 = () => @env.now().reinterpret_as_int64(),
) -> DummyBackend {
  DummyBackend::{ results: [], now, }
}

///|
/// Record the task as a `Ready` row without touching `tx`, returning
/// its new id.
pub impl DBTaskBackend for DummyBackend with fn enqueue(self, _tx, task, args) {
  let id = task_id()
  self.results.push(TaskResult::{
    id,
    task_name: task.name,
    status: Ready,
    args,
    run_after: task.run_after,
    enqueued_at: (self.now)(),
    started_at: None,
    finished_at: None,
    attempts: 0,
    max_attempts: task.max_attempts,
    return_value: None,
    errors: [],
    worker_ids: [],
  })
  id
}

///|
/// Find a recorded row by task name and id.
pub impl DBTaskBackend for DummyBackend with fn get_result(self, task_name, id) {
  self.results
  .iter()
  .find_first(result => result.id == id && result.task_name == task_name)
}

///|
pub extend DummyBackend with DBTaskBackend::{enqueue, get_result}

///|
/// Claim the first runnable row in enqueue order — the in-memory
/// equivalent of the SQL backends' atomic `UPDATE`: due `Ready` rows
/// first (insertion order), or a stale `Running` row when
/// `stale_before` allows reclaiming it within its `max_attempts`
/// budget.
pub impl TaskStore for DummyBackend with fn claim(
  self,
  worker_id~,
  now~,
  stale_before~,
) {
  for i, result in self.results {
    let runnable = match result.status {
      Ready => result.run_after.map_or(true, t => t <= now)
      Running =>
        match stale_before {
          Some(cutoff) =>
            result.started_at.map_or(false, s => s <= cutoff) &&
            result.attempts < result.max_attempts
          None => false
        }
      _ => false
    }
    if runnable {
      let claimed = TaskResult::{
        ..result,
        status: Running,
        attempts: result.attempts + 1,
        started_at: Some(now),
        worker_ids: [..result.worker_ids, worker_id],
      }
      self.results[i] = claimed
      return Some(claimed)
    }
  }
  None
}

///|
/// Persist `result`'s new state back into the recorded row by id.
pub impl TaskStore for DummyBackend with fn save(self, result) {
  for i, stored in self.results {
    if stored.id == result.id {
      if stored.status is Running &&
        stored.attempts == result.attempts &&
        stored.worker_ids == result.worker_ids {
        self.results[i] = result
      }
      return
    }
  }
  fail("tasks: no result with id '\{result.id}'")
}

///|
pub extend DummyBackend with TaskStore::{claim, save}

///|
/// Drop all stored results.
pub fn DummyBackend::clear(self : Self) -> Unit {
  self.results.clear()
}
