///|
/// Execution state of one enqueued task — Django's `TaskResultStatus`.
pub(all) enum TaskResultStatus {
  /// stored, waiting to be claimed (or due at `run_after`).
  Ready
  /// claimed by a worker, currently executing.
  Running
  Successful
  Failed
} derive(Eq, Debug, ToJson, FromJson)

///|
pub extend TaskResultStatus with Eq::{equal, not_equal}

///|
pub extend TaskResultStatus with Debug::{to_repr}

///|
pub extend TaskResultStatus with ToJson::{to_json}

///|
pub extend TaskResultStatus with FromJson::{from_json}

///|
/// One recorded failure of a task attempt — Django's `TaskError`.
/// `exception` is the error's message; `traceback` is reserved for
/// stack information and currently always empty.
pub(all) struct TaskError {
  exception : String
  traceback : String
} derive(Eq, Debug, ToJson, FromJson)

///|
pub extend TaskError with Eq::{equal, not_equal}

///|
pub extend TaskError with Debug::{to_repr}

///|
pub extend TaskError with ToJson::{to_json}

///|
pub extend TaskError with FromJson::{from_json}

///|
/// The result of one enqueued task — Django's `TaskResult`.
///
/// An immutable snapshot of the row's state at the moment it was
/// retrieved: poll `DBTaskBackend::get_result` again for a newer one.
/// `return_value` is only set once `status` is `Successful`.
pub(all) struct TaskResult {
  /// unique id assigned by the backend at enqueue time.
  id : String
  /// `TransactionalTaskDef.name` this result belongs to.
  task_name : String
  status : TaskResultStatus
  /// serialized task arguments.
  args : Json
  /// unix timestamp in ms; `None` runs as soon as possible.
  run_after : Int64?
  /// unix timestamp in ms.
  enqueued_at : Int64
  started_at : Int64?
  finished_at : Int64?
  /// number of times the task has been claimed, counting the in-flight
  /// attempt of a `Running` result.
  attempts : Int32
  /// snapshot of the `max_attempts` the task was enqueued with.
  max_attempts : Int32
  return_value : Json?
  /// one `TaskError` per failed attempt.
  errors : Array[TaskError]
  /// ids of the workers that claimed each attempt.
  worker_ids : Array[String]
} derive(Debug, ToJson, FromJson)

///|
pub extend TaskResult with Debug::{to_repr}

///|
pub extend TaskResult with ToJson::{to_json}

///|
pub extend TaskResult with FromJson::{from_json}

///|
/// Context handed to the task function — Django's `TaskContext`.
/// Always provided; there is no `takes_context` flag.
pub(all) struct TaskContext {
  /// the `TaskResult` row of the running attempt.
  task_result : TaskResult
  /// the current attempt number, 1-based.
  attempt : Int32
}

///|
/// A random task id (UUIDv4).
fn task_id() -> String {
  // rand(16) always yields exactly 16 bytes, so from_bytes cannot fail
  try
    @uuid.from_bytes(@env.rand(16).unwrap()).as_version(V4).to_string()
  catch {
    _ => abort("tasks: uuid encoding failed")
  } noraise {
    s => s
  }
}
