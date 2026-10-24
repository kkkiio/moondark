///|
/// `@moondark_tasks.DBTaskBackend` and `@moondark_tasks.TaskStore`
/// backed by a PostgreSQL table, written in PostgreSQL's native SQL
/// (`$N` placeholders).
///
/// Enqueues are plain `INSERT`s into the caller's transaction — the
/// task row commits atomically with the transaction's other writes,
/// a transactional outbox. Claiming is a single `UPDATE` whose
/// `FOR UPDATE SKIP LOCKED` subquery locks one runnable row per
/// statement: concurrent workers skip each other's rows instead of
/// blocking.
pub struct PostgresTaskBackend {
  db : @moondark_database.DB
  table : String
  now : () -> Int64
}

///|
/// `table` is the name of the task-result table, see `schema.sql` for
/// its schema (including the claim index). It is interpolated into SQL
/// statements verbatim, so it must be a trusted identifier. `now`
/// defaults to wall-clock epoch ms; inject it in tests for
/// deterministic timestamps.
pub fn PostgresTaskBackend::new(
  db : @moondark_database.DB,
  table~ : String = "task_results",
  now~ : () -> Int64 = () => @env.now().reinterpret_as_int64(),
) -> PostgresTaskBackend {
  PostgresTaskBackend::{ db, table, now, }
}

///|
/// Store `task` as a `ready` row inside the caller's transaction — a
/// single `INSERT` that commits atomically with the transaction's
/// other writes, so a worker can only ever see both or neither.
/// Returns the new task id.
pub impl @moondark_tasks.DBTaskBackend for PostgresTaskBackend with fn enqueue(
  self,
  tx,
  task,
  args,
) {
  let id = task_id()
  ignore(
    tx.execute(
      self.insert_sql(),
      params=insert_params(id, task, args, (self.now)()),
    ),
  )
  id
}

///|
/// Fetch a stored result by task name and id; `None` when no row
/// exists.
pub impl @moondark_tasks.DBTaskBackend for PostgresTaskBackend with fn get_result(
  self,
  task_name,
  id,
) {
  let rows = self.db.query_opt(
    "SELECT * FROM \{self.table} WHERE id = $1 AND task_name = $2",
    params=[id, task_name],
  )

  guard rows is Some(row) else { return None }
  Some(result_from_row(row))
}

///|
pub extend PostgresTaskBackend with @moondark_tasks.DBTaskBackend::{
  enqueue,
  get_result,
}

///|
/// Claim the next runnable row in one atomic statement. The
/// subquery's `FOR UPDATE SKIP LOCKED` picks the earliest-enqueued due
/// `ready` row — or a stale `running` one still within its
/// `max_attempts` budget — while concurrent workers skip rows a
/// sibling claim has already locked. `stale_before` of `None`
/// disables reclaim entirely.
pub impl @moondark_tasks.TaskStore for PostgresTaskBackend with fn claim(
  self,
  worker_id~,
  now~,
  stale_before~,
) {
  let rows = self.db.query_opt(
    "UPDATE \{self.table} SET status='running', attempts=attempts+1, started_at=$1, worker_ids = worker_ids || jsonb_build_array($2::text) WHERE id = (SELECT id FROM \{self.table} WHERE (status='ready' AND (run_after IS NULL OR run_after <= $3)) OR (status='running' AND $4::bigint IS NOT NULL AND started_at <= $4 AND attempts < max_attempts) ORDER BY enqueued_at FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING *",
    params=[now, worker_id, now, stale_before],
  )

  guard rows is Some(row) else { return None }
  Some(result_from_row(row))
}

///|
/// Persist the mutable fields of `result` back to its row: the
/// terminal `successful`/`failed` state or a `ready` reschedule for a
/// retry.
pub impl @moondark_tasks.TaskStore for PostgresTaskBackend with fn save(
  self,
  result,
) {
  ignore(
    self.db.execute(
      "UPDATE \{self.table} SET status=$1, run_after=$2, started_at=$3, finished_at=$4, attempts=$5, return_value=$6, errors=$7, worker_ids=$8 WHERE id=$9 AND status='running' AND attempts=$5 AND worker_ids=$8",
      params=[
        status_text(result.status),
        result.run_after,
        result.started_at,
        result.finished_at,
        result.attempts,
        result.return_value,
        Json(result.errors),
        Json(result.worker_ids),
        result.id,
      ],
    ),
  )
}

///|
pub extend PostgresTaskBackend with @moondark_tasks.TaskStore::{claim, save}

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

///|
/// The `INSERT` used by `enqueue`, covering every `TaskResult` field.
/// `JSONB` columns take JSON text, which PostgreSQL parses itself.
fn PostgresTaskBackend::insert_sql(self : Self) -> String {
  "INSERT INTO \{self.table} (id, task_name, status, args, run_after, enqueued_at, started_at, finished_at, attempts, max_attempts, return_value, errors, worker_ids) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)"
}

///|
/// The `INSERT` parameters of a fresh `ready` row, in `insert_sql`
/// column order.
fn insert_params(
  id : String,
  task : @moondark_tasks.TaskArgs,
  args : Json,
  enqueued_at : Int64,
) -> Array[&@moondark_database.ToSql] {
  [
    id,
    task.name,
    "ready",
    args,
    task.run_after,
    enqueued_at,
    (None : Int64?),
    (None : Int64?),
    0,
    task.max_attempts,
    (None : Int64?),
    "[]",
    "[]",
  ]
}

///|
/// Rebuild a `TaskResult` from a `SELECT *`/`RETURNING *` row.
/// JSON columns decode through `FromSql`.
fn result_from_row(
  row : @moondark_database.Row,
) -> @moondark_tasks.TaskResult raise {
  let id : String = row.get_name("id")
  let task_name : String = row.get_name("task_name")
  let status : String = row.get_name("status")
  let args : Json = row.get_name("args")
  let run_after = (row.get_name("run_after") : Int64?)
  let enqueued_at : Int64 = row.get_name("enqueued_at")
  let started_at = (row.get_name("started_at") : Int64?)
  let finished_at = (row.get_name("finished_at") : Int64?)
  let attempts : Int64 = row.get_name("attempts")
  let max_attempts : Int64 = row.get_name("max_attempts")
  let return_value = (row.get_name("return_value") : Json?)
  let errors : Json = row.get_name("errors")
  let worker_ids : Json = row.get_name("worker_ids")
  @moondark_tasks.TaskResult::{
    id,
    task_name,
    status: match status {
      "ready" => Ready
      "running" => Running
      "successful" => Successful
      "failed" => Failed
      _ => fail("tasks: unknown status '\{status}'")
    },
    args,
    run_after,
    enqueued_at,
    started_at,
    finished_at,
    attempts: attempts.to_int(),
    max_attempts: max_attempts.to_int(),
    return_value,
    errors: @json.from_json(errors),
    worker_ids: @json.from_json(worker_ids),
  }
}

///|
/// The `status` column's text form of a `TaskResultStatus`.
fn status_text(status : @moondark_tasks.TaskResultStatus) -> String {
  match status {
    Ready => "ready"
    Running => "running"
    Successful => "successful"
    Failed => "failed"
  }
}
