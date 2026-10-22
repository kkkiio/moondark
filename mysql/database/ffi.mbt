///|
/// MariaDB Connector/C executor handle — one per pooled connection.
/// Owns a worker thread running every libmariadb call for its
/// connection plus a mutex/condvar-guarded FIFO job queue
/// (`mysql_executor.c`).
#external
priv type MysqlExecutor

///|
/// MariaDB connection handle — a `MYSQL*` paired with the executor
/// that serializes its work.
#external
priv type MysqlConn

///|
/// MariaDB prepared-statement handle — a `MYSQL_STMT*` plus the
/// result-column metadata snapshot and result bind buffers filled by
/// the exec job.
#external
priv type MysqlStmt

///|
/// MariaDB job handle — one queued or completed unit of work. Carries
/// the worker-captured errno/SQLSTATE/message and any result payload
/// (conn, stmt, row) published before the completion notification.
#external
priv type MysqlJob

///|
/// One-time `mysql_library_init` (pthread_once'd in C); idempotent.
/// Returns 0 on success, -1 on failure.
extern "c" fn mysql_library_init() -> Int32 = "moondark_mysql_library_init"

///|
/// Spawn the executor's worker thread (`mysql_thread_init` inside) and
/// return the queue handle. `rescode` is 0 on success.
#borrow(rescode)
extern "c" fn mysql_executor_create(rescode : Ref[Int32]) -> MysqlExecutor = "moondark_mysql_executor_create"

///|
/// Stop the worker (`mysql_thread_end` inside), join it and free the
/// executor. Every conn/stmt created through it must already be closed.
extern "c" fn mysql_executor_release(executor : MysqlExecutor) -> Unit = "moondark_mysql_executor_release"

///|
/// Whether the job's result is published (its lifecycle state reached
/// PUBLISHED); call only after the completion notification byte
/// arrived.
extern "c" fn mysql_job_acquire_result(job : MysqlJob) -> Bool = "moondark_mysql_job_acquire_result"

///|
/// Worker-captured `mysql_errno`/`mysql_stmt_errno`; 0 = success.
/// Client-side errors (CR_*) live in 2000..<3000.
extern "c" fn mysql_job_errno(job : MysqlJob) -> Int32 = "moondark_mysql_job_errno"

///|
/// The 5-byte SQLSTATE of a failed job, or empty when none exists.
extern "c" fn mysql_job_sqlstate(job : MysqlJob) -> Bytes = "moondark_mysql_job_sqlstate"

///|
/// The UTF-8 error message of a failed job, or empty.
extern "c" fn mysql_job_message(job : MysqlJob) -> Bytes = "moondark_mysql_job_message"

///|
/// Free the job and its result payload. Returns immediately when the
/// job never published a result.
extern "c" fn mysql_job_release(job : MysqlJob) -> Unit = "moondark_mysql_job_release"

///|
/// Queue a connect job (`mysql_init` + `mysql_real_connect` with
/// `CLIENT_MULTI_STATEMENTS` on the worker). String inputs are
/// deep-copied during this submit call; empty password/database map to
/// NULL. `rescode` reports submit-time failures only.
#borrow(host, user, password, database, rescode)
extern "c" fn mysql_connect_job(
  executor : MysqlExecutor,
  host : Bytes,
  port : Int32,
  user : Bytes,
  password : Bytes,
  database : Bytes,
  notification : @types.Fd,
  rescode : Ref[Int32],
) -> MysqlJob = "moondark_mysql_connect_job"

///|
/// Move the conn wrapper out of a successful connect job; NULL on
/// failure — only call when `mysql_job_errno` is 0.
extern "c" fn mysql_job_take_conn(job : MysqlJob) -> MysqlConn = "moondark_mysql_job_take_conn"

///|
/// Queue a multi-statement `mysql_real_query` job (worker drains every
/// result set via `mysql_store_result`/`mysql_next_result`). `sql` is
/// deep-copied during this submit call.
#borrow(sql, rescode)
extern "c" fn mysql_query_job(
  executor : MysqlExecutor,
  conn : MysqlConn,
  sql : Bytes,
  notification : @types.Fd,
  rescode : Ref[Int32],
) -> MysqlJob = "moondark_mysql_query_job"

///|
/// Queue a `mysql_ping` job.
#borrow(rescode)
extern "c" fn mysql_ping_job(
  executor : MysqlExecutor,
  conn : MysqlConn,
  notification : @types.Fd,
  rescode : Ref[Int32],
) -> MysqlJob = "moondark_mysql_ping_job"

///|
/// Queue a session-reset job.
#borrow(rescode)
extern "c" fn mysql_reset_job(
  executor : MysqlExecutor,
  conn : MysqlConn,
  notification : @types.Fd,
  rescode : Ref[Int32],
) -> MysqlJob = "moondark_mysql_reset_job"

///|
/// Queue a connection-close job (`mysql_close` + free on the worker).
/// The conn handle is invalid afterwards.
#borrow(rescode)
extern "c" fn mysql_conn_close_job(
  executor : MysqlExecutor,
  conn : MysqlConn,
  notification : @types.Fd,
  rescode : Ref[Int32],
) -> MysqlJob = "moondark_mysql_conn_close_job"

///|
/// Queue a `mysql_stmt_prepare` job. `sql` is deep-copied during this
/// submit call.
#borrow(sql, rescode)
extern "c" fn mysql_prepare_job(
  executor : MysqlExecutor,
  conn : MysqlConn,
  sql : Bytes,
  notification : @types.Fd,
  rescode : Ref[Int32],
) -> MysqlJob = "moondark_mysql_prepare_job"

///|
/// Move the stmt wrapper out of a successful prepare job; NULL on
/// failure — only call when `mysql_job_errno` is 0.
extern "c" fn mysql_job_take_stmt(job : MysqlJob) -> MysqlStmt = "moondark_mysql_job_take_stmt"

///|
/// `mysql_stmt_param_count` snapshot of a completed prepare job; -1 on
/// failure.
extern "c" fn mysql_job_param_count(job : MysqlJob) -> Int32 = "moondark_mysql_job_param_count"

///|
/// Create the shared exec job for `Stmt::exec`/`Stmt::query`. The job
/// is NOT enqueued: the parameter bind setters below must fill `job`
/// first, then `moondark_mysql_exec_submit` makes it runnable.
#borrow(rescode)
extern "c" fn mysql_exec_job(
  executor : MysqlExecutor,
  stmt : MysqlStmt,
  notification : @types.Fd,
  rescode : Ref[Int32],
) -> MysqlJob = "moondark_mysql_exec_job"

///|
/// Enqueue a bind-filled exec job created by `moondark_mysql_exec_job`
/// after all bind setters have run. `rescode` reports submit-time
/// failures; on failure the job still needs `mysql_job_release`.
#borrow(rescode)
extern "c" fn mysql_exec_submit(job : MysqlJob, rescode : Ref[Int32]) -> Unit = "moondark_mysql_exec_submit"

///|
/// Bind a NULL to exec-job parameter `idx`.
extern "c" fn mysql_bind_null(job : MysqlJob, idx : Int32) -> Unit = "moondark_mysql_bind_null"

///|
/// Bind an int64 to exec-job parameter `idx`.
extern "c" fn mysql_bind_int64(
  job : MysqlJob,
  idx : Int32,
  value : Int64,
) -> Unit = "moondark_mysql_bind_int64"

///|
/// Bind a boolean (MYSQL_TYPE_TINY, 0/1) to exec-job parameter `idx`.
extern "c" fn mysql_bind_bool(
  job : MysqlJob,
  idx : Int32,
  value : Int32,
) -> Unit = "moondark_mysql_bind_bool"

///|
/// Bind a double to exec-job parameter `idx`.
extern "c" fn mysql_bind_double(
  job : MysqlJob,
  idx : Int32,
  value : Double,
) -> Unit = "moondark_mysql_bind_double"

///|
/// Bind UTF-8 text to exec-job parameter `idx`; deep-copied by the
/// call.
#borrow(utf8)
extern "c" fn mysql_bind_string(
  job : MysqlJob,
  idx : Int32,
  utf8 : Bytes,
) -> Unit = "moondark_mysql_bind_string"

///|
/// Bind raw bytes to exec-job parameter `idx`; deep-copied by the
/// call.
#borrow(bytes)
extern "c" fn mysql_bind_blob(
  job : MysqlJob,
  idx : Int32,
  bytes : Bytes,
) -> Unit = "moondark_mysql_bind_blob"

///|
/// Bind an epoch-microseconds-UTC timestamp to exec-job parameter
/// `idx` (worker renders it as MYSQL_TYPE_DATETIME).
extern "c" fn mysql_bind_timestamp(
  job : MysqlJob,
  idx : Int32,
  epoch_micros : Int64,
) -> Unit = "moondark_mysql_bind_timestamp"

///|
/// Whether a completed exec job produced a result set (and populated
/// the stmt's column metadata).
extern "c" fn mysql_job_has_result(job : MysqlJob) -> Bool = "moondark_mysql_job_has_result"

///|
/// `mysql_affected_rows` of a completed exec job; -1 when the
/// statement produced none.
extern "c" fn mysql_job_affected_rows(job : MysqlJob) -> Int64 = "moondark_mysql_job_affected_rows"

///|
/// `mysql_insert_id` of a completed exec job; 0 when none was
/// generated.
extern "c" fn mysql_job_insert_id(job : MysqlJob) -> Int64 = "moondark_mysql_job_insert_id"

///|
/// Column count of the stmt's current result-set metadata.
extern "c" fn mysql_stmt_col_count(stmt : MysqlStmt) -> Int32 = "moondark_mysql_stmt_col_count"

///|
/// UTF-8 name of result column `idx`.
extern "c" fn mysql_stmt_col_name(stmt : MysqlStmt, idx : Int32) -> Bytes = "moondark_mysql_stmt_col_name"

///|
/// Driver `kind` code of result column `idx`: 0 null, 1 Int64,
/// 2 Double, 3 String, 4 Bytes, 5 Timestamp.
extern "c" fn mysql_stmt_col_kind(stmt : MysqlStmt, idx : Int32) -> Int32 = "moondark_mysql_stmt_col_kind"

///|
/// Queue a single-row `mysql_stmt_fetch` job.
#borrow(rescode)
extern "c" fn mysql_fetch_job(
  executor : MysqlExecutor,
  stmt : MysqlStmt,
  notification : @types.Fd,
  rescode : Ref[Int32],
) -> MysqlJob = "moondark_mysql_fetch_job"

///|
/// Whether a completed fetch job fetched a row.
extern "c" fn mysql_job_has_row(job : MysqlJob) -> Bool = "moondark_mysql_job_has_row"

///|
/// Whether column `idx` of the fetched row is NULL.
extern "c" fn mysql_job_col_is_null(job : MysqlJob, idx : Int32) -> Bool = "moondark_mysql_job_col_is_null"

///|
/// int64 payload of fetched column `idx` (kind 1).
extern "c" fn mysql_job_col_i64(job : MysqlJob, idx : Int32) -> Int64 = "moondark_mysql_job_col_i64"

///|
/// double payload of fetched column `idx` (kind 2).
extern "c" fn mysql_job_col_double(job : MysqlJob, idx : Int32) -> Double = "moondark_mysql_job_col_double"

///|
/// Epoch-microseconds-UTC payload of fetched column `idx` (kind 5).
extern "c" fn mysql_job_col_time_micros(job : MysqlJob, idx : Int32) -> Int64 = "moondark_mysql_job_col_time_micros"

///|
/// Byte payload of fetched column `idx` (kind 3 = UTF-8 text,
/// kind 4 = raw bytes).
extern "c" fn mysql_job_col_bytes(job : MysqlJob, idx : Int32) -> Bytes = "moondark_mysql_job_col_bytes"

///|
/// Queue a `mysql_stmt_free_result` job (releases the stored result
/// set on the worker without closing the statement — used by
/// `Rows::close` so cached statements stay reusable).
#borrow(rescode)
extern "c" fn mysql_result_close_job(
  executor : MysqlExecutor,
  stmt : MysqlStmt,
  notification : @types.Fd,
  rescode : Ref[Int32],
) -> MysqlJob = "moondark_mysql_result_close_job"

///|
/// Queue a `mysql_stmt_close` job (frees the wrapper's columns and
/// bind buffers on the worker). The stmt handle is invalid afterwards.
#borrow(rescode)
extern "c" fn mysql_stmt_close_job(
  executor : MysqlExecutor,
  stmt : MysqlStmt,
  notification : @types.Fd,
  rescode : Ref[Int32],
) -> MysqlJob = "moondark_mysql_stmt_close_job"
