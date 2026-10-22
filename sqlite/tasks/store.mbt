///|
/// `@moondark_tasks.DBTaskBackend` and `@moondark_tasks.TaskStore`
/// backed by a SQLite table — one row per `TaskResult`, written in
/// SQLite's native SQL (`?` placeholders).
///
/// `args`, `return_value`, `errors` and `worker_ids` are stored as
/// JSON text. `claim` is a single `UPDATE ... WHERE id = (SELECT ...
/// LIMIT 1) RETURNING ...`: SQLite serializes writers, so the
/// row-picking subselect and the update cannot race — there is no
/// `FOR UPDATE` and none is needed.
struct SqliteTaskBackend {
  db : @sql.DB
  table : String
  now : () -> Int64
}

///|
/// `table` is the name of the task-results table, see `schema.sql` for
/// its schema (including the claim index and the recommended
/// `busy_timeout` pragma). It is interpolated into SQL statements
/// verbatim, so it must be a trusted identifier. `now` supplies the
/// unix-ms timestamp stamped into `enqueued_at`; inject it in tests
/// for a deterministic clock.
pub fn SqliteTaskBackend::new(
  db : @sql.DB,
  table~ : String = "task_results",
  now~ : () -> Int64 = () => @env.now().reinterpret_as_int64(),
) -> SqliteTaskBackend {
  SqliteTaskBackend::{ db, table, now, }
}

///|
/// Store `task` as a `Ready` row inside the caller's transaction — a
/// single `INSERT` that commits atomically with the transaction's
/// other writes, so a worker can only ever see both or neither.
/// Returns the new task id.
pub impl @moondark_tasks.DBTaskBackend for SqliteTaskBackend with fn enqueue(
  self,
  tx,
  task,
  args,
) {
  let id = result_id()
  ignore(
    tx.execute(
      self.insert_sql(),
      params=insert_params(id, task, args, (self.now)()),
    ),
  )
  id
}

///|
/// Fetch a result row by task name and id.
pub impl @moondark_tasks.DBTaskBackend for SqliteTaskBackend with fn get_result(
  self,
  task_name,
  id,
) {
  let rows = self.db.query(
    "SELECT \{RESULT_COLUMNS} FROM \{self.table} WHERE id = ? AND task_name = ?",
    params=[id, task_name],
  )
  defer rows.close()
  guard rows.next() is Some(row) else { return None }
  Some(result_of_row(row))
}

///|
pub extend SqliteTaskBackend with @moondark_tasks.DBTaskBackend::{
  enqueue,
  get_result,
}

///|
/// Atomically claim the next runnable row for `worker_id` — see
/// `TaskStore::claim` for the contract. One statement: the subselect
/// picks the earliest-enqueued due `Ready` row (or a `Running` row
/// gone stale before `stale_before`, within its `max_attempts`
/// budget) and the update flips it to `Running`, incrementing
/// `attempts`, setting `started_at` and appending `worker_id` to the
/// `worker_ids` JSON array.
pub impl @moondark_tasks.TaskStore for SqliteTaskBackend with fn claim(
  self,
  worker_id~,
  now~,
  stale_before~,
) {
  let stale = opt_int64(stale_before)
  // One statement: the subselect and the update execute under the same
  // write lock, so the pick cannot race a concurrent claim.
  let rows = self.db.query(
    "UPDATE \{self.table} SET status = 'running', attempts = attempts + 1, started_at = ?, worker_ids = json_insert(worker_ids, '$[#]', ?) WHERE id = (SELECT id FROM \{self.table} WHERE (status = 'ready' AND (run_after IS NULL OR run_after <= ?)) OR (status = 'running' AND ? IS NOT NULL AND started_at <= ? AND attempts < max_attempts) ORDER BY enqueued_at LIMIT 1) RETURNING \{RESULT_COLUMNS}",
    params=[now, worker_id, now, stale, stale],
  )
  defer rows.close()
  guard rows.next() is Some(row) else { return None }
  Some(result_of_row(row))
}

///|
/// Persist `result` as the row's new state: a terminal
/// `Successful`/`Failed`, or a `Ready` reschedule for a retry.
pub impl @moondark_tasks.TaskStore for SqliteTaskBackend with fn save(
  self,
  result,
) {
  ignore(
    self.db.execute(
      "UPDATE \{self.table} SET status = ?, run_after = ?, started_at = ?, finished_at = ?, attempts = ?, return_value = ?, errors = ?, worker_ids = ? WHERE id = ?",
      params=[
        status_text(result.status),
        opt_int64(result.run_after),
        opt_int64(result.started_at),
        opt_int64(result.finished_at),
        result.attempts,
        opt_json(result.return_value),
        Json(result.errors).stringify(),
        Json(result.worker_ids).stringify(),
        result.id,
      ],
    ),
  )
}

///|
pub extend SqliteTaskBackend with @moondark_tasks.TaskStore::{claim, save}

///|
/// The selected column list shared by `get_result`, `claim`'s
/// `RETURNING` clause and `result_of_row`.
const RESULT_COLUMNS : String = "id, task_name, status, args, run_after, enqueued_at, started_at, finished_at, attempts, max_attempts, return_value, errors, worker_ids"

///|
/// The `INSERT` used by `enqueue`, in the column order of
/// `insert_params`.
fn SqliteTaskBackend::insert_sql(self : Self) -> String {
  "INSERT INTO \{self.table} (\{RESULT_COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
}

///|
/// The `INSERT` parameters of a fresh `Ready` row, in
/// `RESULT_COLUMNS` order.
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
    opt_int64(task.run_after),
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
/// Rebuild the `TaskResult` of one row selected with
/// `RESULT_COLUMNS`.
fn result_of_row(row : @sql.Row) -> @moondark_tasks.TaskResult raise {
  let return_value = match row.get("return_value") {
    Some(@driver.Value::String(s)) => Some(@json.parse(s))
    Some(@driver.Value::Null) => None
    _ => fail("tasks: malformed return_value column")
  }
  let errors : Array[@moondark_tasks.TaskError] = @json.from_json(
    @json.parse(text_column(row, "errors")),
  )
  let worker_ids : Array[String] = @json.from_json(
    @json.parse(text_column(row, "worker_ids")),
  )
  @moondark_tasks.TaskResult::{
    id: text_column(row, "id"),
    task_name: text_column(row, "task_name"),
    status: status_of(text_column(row, "status")),
    args: @json.parse(text_column(row, "args")),
    run_after: opt_int64_column(row, "run_after"),
    enqueued_at: int64_column(row, "enqueued_at"),
    started_at: opt_int64_column(row, "started_at"),
    finished_at: opt_int64_column(row, "finished_at"),
    attempts: int64_column(row, "attempts").to_int(),
    max_attempts: int64_column(row, "max_attempts").to_int(),
    return_value,
    errors,
    worker_ids,
  }
}

///|
/// The stored status text of each `TaskResultStatus`.
fn status_text(status : @moondark_tasks.TaskResultStatus) -> String {
  match status {
    Ready => "ready"
    Running => "running"
    Successful => "successful"
    Failed => "failed"
  }
}

///|
/// Inverse of `status_text`; fails on an unrecognized stored value.
fn status_of(text : String) -> @moondark_tasks.TaskResultStatus raise {
  match text {
    "ready" => @moondark_tasks.TaskResultStatus::Ready
    "running" => @moondark_tasks.TaskResultStatus::Running
    "successful" => @moondark_tasks.TaskResultStatus::Successful
    "failed" => @moondark_tasks.TaskResultStatus::Failed
    _ => fail("tasks: unknown stored status '\{text}'")
  }
}

///|
/// `NULL` or the value, for the optional `BIGINT` columns.
fn opt_int64(value : Int64?) -> @driver.Value {
  match value {
    Some(v) => @driver.Value::Int64(v)
    None => @driver.Value::Null
  }
}

///|
/// `NULL` or the stringified JSON, for `return_value`.
fn opt_json(value : Json?) -> @driver.Value {
  match value {
    Some(v) => @driver.Value::String(v.stringify())
    None => @driver.Value::Null
  }
}

///|
/// The required `TEXT` column `name` of `row`.
fn text_column(row : @sql.Row, name : String) -> String raise {
  guard row.get(name) is Some(@driver.Value::String(s)) else {
    fail("tasks: malformed \{name} column")
  }
  s
}

///|
/// The required `INTEGER`/`BIGINT` column `name` of `row`.
fn int64_column(row : @sql.Row, name : String) -> Int64 raise {
  guard row.get(name) is Some(@driver.Value::Int64(v)) else {
    fail("tasks: malformed \{name} column")
  }
  v
}

///|
/// The nullable `BIGINT` column `name` of `row`.
fn opt_int64_column(row : @sql.Row, name : String) -> Int64? raise {
  match row.get(name) {
    Some(@driver.Value::Int64(v)) => Some(v)
    Some(@driver.Value::Null) => None
    _ => fail("tasks: malformed \{name} column")
  }
}

///|
/// A random result id (UUIDv4).
fn result_id() -> String {
  // rand(16) always yields exactly 16 bytes, so from_bytes cannot fail
  try
    @uuid.from_bytes(@env.rand(16).unwrap()).as_version(V4).to_string()
  catch {
    _ => abort("tasks: uuid encoding failed")
  } noraise {
    s => s
  }
}
