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
  db : @sql.DB
  table : String
  now : () -> Int64
}

///|
/// `table` is the name of the task-result table, see `migrate` for its
/// schema. It is interpolated into SQL statements verbatim, so it must
/// be a trusted identifier. `now` defaults to wall-clock epoch ms;
/// inject it in tests for deterministic timestamps.
pub fn PostgresTaskBackend::new(
  db : @sql.DB,
  table~ : String = "task_results",
  now~ : () -> Int64 = () => @env.now().reinterpret_as_int64(),
) -> PostgresTaskBackend {
  PostgresTaskBackend::{ db, table, now, }
}

///|
/// Create the task-result table and its claim index if they do not
/// exist. The partial index covers exactly the rows `claim` scans:
/// runnable `ready` rows plus reclaimable `running` ones.
pub async fn PostgresTaskBackend::migrate(self : Self) -> Unit {
  ignore(
    self.db.execute(
      "CREATE TABLE IF NOT EXISTS \{self.table} (id TEXT PRIMARY KEY, task_name TEXT NOT NULL, status TEXT NOT NULL, args JSONB NOT NULL, run_after BIGINT NULL, enqueued_at BIGINT NOT NULL, started_at BIGINT NULL, finished_at BIGINT NULL, attempts INTEGER NOT NULL, max_attempts INTEGER NOT NULL, return_value JSONB NULL, errors JSONB NOT NULL, worker_ids JSONB NOT NULL)",
    ),
  )
  ignore(
    self.db.execute(
      "CREATE INDEX IF NOT EXISTS \{self.table}_claim_idx ON \{self.table} (enqueued_at) WHERE status IN ('ready','running')",
    ),
  )
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
  let rows = self.db.query(
    "SELECT * FROM \{self.table} WHERE id = $1 AND task_name = $2",
    params=[id, task_name],
  )
  defer rows.close()
  guard rows.next() is Some(row) else { return None }
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
  let rows = self.db.query(
    "UPDATE \{self.table} SET status='running', attempts=attempts+1, started_at=$1, worker_ids = worker_ids || jsonb_build_array($2::text) WHERE id = (SELECT id FROM \{self.table} WHERE (status='ready' AND (run_after IS NULL OR run_after <= $3)) OR (status='running' AND $4::bigint IS NOT NULL AND started_at <= $4 AND attempts < max_attempts) ORDER BY enqueued_at FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING *",
    params=[now, worker_id, now, timestamp(stale_before)],
  )
  defer rows.close()
  guard rows.next() is Some(row) else { return None }
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
      "UPDATE \{self.table} SET status=$1, run_after=$2, started_at=$3, finished_at=$4, attempts=$5, return_value=$6, errors=$7, worker_ids=$8 WHERE id=$9",
      params=[
        status_text(result.status),
        timestamp(result.run_after),
        timestamp(result.started_at),
        timestamp(result.finished_at),
        result.attempts,
        json_or_null(result.return_value),
        Json(result.errors).stringify(),
        Json(result.worker_ids).stringify(),
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
) -> Array[&@driver.Valuer] {
  [
    id,
    task.name,
    "ready",
    args.stringify(),
    timestamp(task.run_after),
    enqueued_at,
    @driver.Value::Null,
    @driver.Value::Null,
    0,
    task.max_attempts,
    @driver.Value::Null,
    "[]",
    "[]",
  ]
}

///|
/// Rebuild a `TaskResult` from a `SELECT *`/`RETURNING *` row.
/// `JSONB` columns come back as `@driver.Value::String` holding JSON
/// text and are re-parsed.
fn result_from_row(row : @sql.Row) -> @moondark_tasks.TaskResult raise {
  guard row.get("id") is Some(@driver.Value::String(id)) else {
    fail("tasks: malformed id")
  }
  guard row.get("task_name") is Some(@driver.Value::String(task_name)) else {
    fail("tasks: malformed task_name")
  }
  guard row.get("status") is Some(@driver.Value::String(status)) else {
    fail("tasks: malformed status")
  }
  guard row.get("args") is Some(@driver.Value::String(args_text)) else {
    fail("tasks: malformed args")
  }
  let run_after = match row.get("run_after") {
    Some(@driver.Value::Null) => None
    Some(@driver.Value::Int64(v)) => Some(v)
    _ => fail("tasks: malformed run_after")
  }
  guard row.get("enqueued_at") is Some(@driver.Value::Int64(enqueued_at)) else {
    fail("tasks: malformed enqueued_at")
  }
  let started_at = match row.get("started_at") {
    Some(@driver.Value::Null) => None
    Some(@driver.Value::Int64(v)) => Some(v)
    _ => fail("tasks: malformed started_at")
  }
  let finished_at = match row.get("finished_at") {
    Some(@driver.Value::Null) => None
    Some(@driver.Value::Int64(v)) => Some(v)
    _ => fail("tasks: malformed finished_at")
  }
  guard row.get("attempts") is Some(@driver.Value::Int64(attempts)) else {
    fail("tasks: malformed attempts")
  }
  guard row.get("max_attempts") is Some(@driver.Value::Int64(max_attempts)) else {
    fail("tasks: malformed max_attempts")
  }
  let return_value = match row.get("return_value") {
    Some(@driver.Value::Null) => None
    Some(@driver.Value::String(text)) => Some(@json.parse(text))
    _ => fail("tasks: malformed return_value")
  }
  guard row.get("errors") is Some(@driver.Value::String(errors_text)) else {
    fail("tasks: malformed errors")
  }
  guard row.get("worker_ids") is Some(@driver.Value::String(worker_ids_text)) else {
    fail("tasks: malformed worker_ids")
  }
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
    args: @json.parse(args_text),
    run_after,
    enqueued_at,
    started_at,
    finished_at,
    attempts: attempts.to_int(),
    max_attempts: max_attempts.to_int(),
    return_value,
    errors: @json.from_json(@json.parse(errors_text)),
    worker_ids: @json.from_json(@json.parse(worker_ids_text)),
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

///|
/// `BIGINT` columns are nullable: `None` binds SQL `NULL`.
fn timestamp(t : Int64?) -> @driver.Value {
  t.map_or(@driver.Value::Null, v => @driver.Value::Int64(v))
}

///|
/// `JSONB` columns are nullable: `None` binds SQL `NULL`, `Some` binds
/// its JSON text.
fn json_or_null(value : Json?) -> @driver.Value {
  value.map_or(@driver.Value::Null, v => @driver.Value::String(v.stringify()))
}
