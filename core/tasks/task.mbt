///|
/// Raised when a task is declared with an invalid configuration —
/// Django's `InvalidTask`.
pub(all) suberror InvalidTask {
  InvalidTask(String)
}

///|
/// Producer-side handle of a background task: a name, a retry budget,
/// and the static type `T` of its arguments — what a producer needs
/// to enqueue work, without the task function itself.
///
/// `T` links the two ends of the queue: `enqueue` requires
/// `T : ToJson` to serialize `args` into the task row, and
/// `Task::bind` requires `T : FromJson` to decode it back for
/// the task function — one declaration, typed on both sides.
#warnings("-unused_type_variable")
pub(all) struct Task[T] {
  /// unique name; a worker resolves a claimed row back to a
  /// `TaskHandler` through it.
  name : String
  /// claim budget written onto every row this task enqueues: total
  /// attempts allowed, counting the first (>= 1). `1` means a failed
  /// task is never retried.
  max_attempts : Int32
}

///|
/// Define a task — the equivalent of Django's `@task` decorator.
/// `max_attempts` defaults to 5.
pub fn[T] Task::new(
  name~ : String,
  max_attempts~ : Int32 = 5,
) -> Task[T] raise InvalidTask {
  if max_attempts < 1 {
    raise InvalidTask("tasks: max_attempts must be at least 1")
  }
  Task::{ name, max_attempts, }
}

///|
/// Enqueue one run of this task inside `tx` — the task row commits
/// atomically with the transaction's other writes, so a worker can
/// only ever see both or neither (the transactional outbox). Returns
/// the new task id. `run_after` defers the first attempt to that
/// unix-ms timestamp; `None` runs as soon as a worker claims it.
pub async fn[T : ToJson] Task::enqueue(
  self : Task[T],
  backend : &DBTaskBackend,
  tx : @database.Transaction,
  args~ : T,
  run_after? : Int64,
) -> String {
  backend.enqueue(
    tx,
    TaskArgs::{ name: self.name, run_after, max_attempts: self.max_attempts, },
    args.to_json(),
  )
}

///|
/// Look up a result row of this task by id — e.g. to answer a
/// "is my report done yet" status poll.
pub async fn[T] Task::get_result(
  self : Task[T],
  backend : &DBTaskBackend,
  id : String,
) -> TaskResult? {
  backend.get_result(self.name, id)
}

///|
/// Bind this task definition to a typed execution function for a
/// `Worker`. `args` are decoded through `T : FromJson`; a row whose
/// serialized args fail to decode fails the attempt like any other
/// error.
pub fn[T : FromJson] Task::bind(
  self : Task[T],
  func : async (TaskContext, T) -> Json,
) -> TaskHandler {
  TaskHandler::{
    name: self.name,
    func: (ctx, args) => func(ctx, @json.from_json(args)),
  }
}
