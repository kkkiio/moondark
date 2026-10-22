///|
/// A submitted MariaDB job plus the read end of its completion pipe.
/// Each constructor hands the pipe's write-end fd to the C submit
/// call; the worker writes one byte after publishing the result.
priv struct AsyncJob {
  handle : MysqlJob
  mut notification : @pipe.PipeRead?
}

///|
/// Create the completion pipe, hand its write end to `submit` and wrap
/// the returned job. The read end is kept for `AsyncJob::wait`; a
/// failed submit leaves the caller to `release` the returned job.
fn submit_job(submit : (@types.Fd) -> MysqlJob) -> AsyncJob raise {
  let (notification, notifier) = @pipe.pipe()
  defer notifier.close()
  AsyncJob::{ handle: submit(notifier.fd()), notification: Some(notification), }
}

///|
/// Submit a connect job carrying the DSN coordinates. `rescode`
/// reports submit-time failures only; the handshake outcome is read
/// off the job after `wait`.
fn connect_job(
  executor : MysqlExecutor,
  host : Bytes,
  port : Int32,
  user : Bytes,
  password : Bytes,
  database : Bytes,
  rescode : Ref[Int32],
) -> AsyncJob raise {
  submit_job(fd => {
    mysql_connect_job(
      executor, host, port, user, password, database, fd, rescode,
    )
  })
}

///|
/// Submit a multi-statement `mysql_real_query` job (`begin`, `commit`,
/// `rollback`, `ping`, `execute_script`).
fn query_job(
  executor : MysqlExecutor,
  conn : MysqlConn,
  sql : Bytes,
  rescode : Ref[Int32],
) -> AsyncJob raise {
  submit_job(fd => mysql_query_job(executor, conn, sql, fd, rescode))
}

///|
/// Submit a `mysql_ping` job.
fn ping_job(
  executor : MysqlExecutor,
  conn : MysqlConn,
  rescode : Ref[Int32],
) -> AsyncJob raise {
  submit_job(fd => mysql_ping_job(executor, conn, fd, rescode))
}

///|
/// Submit a session-reset job.
fn reset_job(
  executor : MysqlExecutor,
  conn : MysqlConn,
  rescode : Ref[Int32],
) -> AsyncJob raise {
  submit_job(fd => mysql_reset_job(executor, conn, fd, rescode))
}

///|
/// Submit a connection-close job; the conn handle is invalid once the
/// job completes.
fn conn_close_job(
  executor : MysqlExecutor,
  conn : MysqlConn,
  rescode : Ref[Int32],
) -> AsyncJob raise {
  submit_job(fd => mysql_conn_close_job(executor, conn, fd, rescode))
}

///|
/// Submit a `mysql_stmt_prepare` job.
fn prepare_job(
  executor : MysqlExecutor,
  conn : MysqlConn,
  sql : Bytes,
  rescode : Ref[Int32],
) -> AsyncJob raise {
  submit_job(fd => mysql_prepare_job(executor, conn, sql, fd, rescode))
}

///|
/// Create the shared exec job for `Stmt::exec`/`Stmt::query`. The job
/// is not enqueued yet: call the `bind_*` setters, then `submit`,
/// then `wait`.
fn exec_job(
  executor : MysqlExecutor,
  stmt : MysqlStmt,
  rescode : Ref[Int32],
) -> AsyncJob raise {
  submit_job(fd => mysql_exec_job(executor, stmt, fd, rescode))
}

///|
/// Submit a single-row `mysql_stmt_fetch` job.
fn fetch_job(
  executor : MysqlExecutor,
  stmt : MysqlStmt,
  rescode : Ref[Int32],
) -> AsyncJob raise {
  submit_job(fd => mysql_fetch_job(executor, stmt, fd, rescode))
}

///|
/// Submit a `mysql_stmt_close` job; the stmt handle is invalid once
/// the job completes.
fn stmt_close_job(
  executor : MysqlExecutor,
  stmt : MysqlStmt,
  rescode : Ref[Int32],
) -> AsyncJob raise {
  submit_job(fd => mysql_stmt_close_job(executor, stmt, fd, rescode))
}

///|
/// Submit a `mysql_stmt_free_result` job: releases the stmt's stored
/// result set without closing the statement.
fn result_close_job(
  executor : MysqlExecutor,
  stmt : MysqlStmt,
  rescode : Ref[Int32],
) -> AsyncJob raise {
  submit_job(fd => mysql_result_close_job(executor, stmt, fd, rescode))
}

///|
/// Block until the worker publishes the job's result, retrying the
/// notification read on EINTR and nonblocking would-block.
async fn AsyncJob::wait(self : AsyncJob) -> Unit {
  guard self.notification is Some(notification) else {
    abort("mysql: asynchronous job lost its completion notification")
  }
  let signal = FixedArray::make(1, b'\x00')
  for ;; {
    ignore(notification.read(signal, max_len=1)) catch {
      @os_error.OSError(_) as error if error.is_EINTR() ||
        error.is_nonblocking_io_error() => continue
      _ => abort("mysql: asynchronous completion notification failed")
    }
    break
  }
  if !self.acquire_result() {
    abort("mysql: asynchronous job woke before publishing its result")
  }
}

///|
fn AsyncJob::acquire_result(self : AsyncJob) -> Bool {
  mysql_job_acquire_result(self.handle)
}

///|
/// Worker-captured errno; 0 = success.
fn AsyncJob::errno(self : AsyncJob) -> Int32 {
  mysql_job_errno(self.handle)
}

///|
/// The job's error rendered as `SQLSTATE message` (message alone when
/// no SQLSTATE was captured), UTF-8 decoded lossily.
fn AsyncJob::error(self : AsyncJob) -> Error {
  let sqlstate = @utf8.decode_lossy(mysql_job_sqlstate(self.handle)[:])
  let message = @utf8.decode_lossy(mysql_job_message(self.handle)[:])
  Failure(if sqlstate.is_empty() { message } else { "\{sqlstate} \{message}" })
}

///|
/// Close the notification pipe and free the job's C storage.
fn AsyncJob::release(self : AsyncJob) -> Unit {
  if self.notification is Some(notification) {
    notification.close()
    self.notification = None
  }
  mysql_job_release(self.handle)
}

///|
/// Move the conn wrapper out of a successful connect job.
fn AsyncJob::take_conn(self : AsyncJob) -> MysqlConn {
  mysql_job_take_conn(self.handle)
}

///|
/// Move the stmt wrapper out of a successful prepare job.
fn AsyncJob::take_stmt(self : AsyncJob) -> MysqlStmt {
  mysql_job_take_stmt(self.handle)
}

///|
/// Parameter count captured by a completed prepare job (-1 on
/// failure).
fn AsyncJob::param_count(self : AsyncJob) -> Int32 {
  mysql_job_param_count(self.handle)
}

///|
/// Whether a completed exec job produced a result set.
fn AsyncJob::has_result(self : AsyncJob) -> Bool {
  mysql_job_has_result(self.handle)
}

///|
/// `mysql_affected_rows` of a completed exec job; -1 when none.
fn AsyncJob::affected_rows(self : AsyncJob) -> Int64 {
  mysql_job_affected_rows(self.handle)
}

///|
/// `mysql_insert_id` of a completed exec job; 0 when none.
fn AsyncJob::insert_id(self : AsyncJob) -> Int64 {
  mysql_job_insert_id(self.handle)
}

///|
/// Whether a completed fetch job fetched a row.
fn AsyncJob::has_row(self : AsyncJob) -> Bool {
  mysql_job_has_row(self.handle)
}

///|
/// Whether column `idx` of the fetched row is NULL.
fn AsyncJob::col_is_null(self : AsyncJob, idx : Int32) -> Bool {
  mysql_job_col_is_null(self.handle, idx)
}

///|
/// int64 payload of fetched column `idx`.
fn AsyncJob::col_i64(self : AsyncJob, idx : Int32) -> Int64 {
  mysql_job_col_i64(self.handle, idx)
}

///|
/// double payload of fetched column `idx`.
fn AsyncJob::col_double(self : AsyncJob, idx : Int32) -> Double {
  mysql_job_col_double(self.handle, idx)
}

///|
/// Epoch-microseconds-UTC payload of fetched column `idx`.
fn AsyncJob::col_time_micros(self : AsyncJob, idx : Int32) -> Int64 {
  mysql_job_col_time_micros(self.handle, idx)
}

///|
/// Byte payload of fetched column `idx`.
fn AsyncJob::col_bytes(self : AsyncJob, idx : Int32) -> Bytes {
  mysql_job_col_bytes(self.handle, idx)
}

///|
/// Bind a NULL to exec-job parameter `idx`.
fn AsyncJob::bind_null(self : AsyncJob, idx : Int32) -> Unit {
  mysql_bind_null(self.handle, idx)
}

///|
/// Bind an int64 to exec-job parameter `idx`.
fn AsyncJob::bind_int64(self : AsyncJob, idx : Int32, value : Int64) -> Unit {
  mysql_bind_int64(self.handle, idx, value)
}

///|
/// Bind a boolean (0/1) to exec-job parameter `idx`.
fn AsyncJob::bind_bool(self : AsyncJob, idx : Int32, value : Bool) -> Unit {
  mysql_bind_bool(self.handle, idx, if value { 1 } else { 0 })
}

///|
/// Bind a double to exec-job parameter `idx`.
fn AsyncJob::bind_double(self : AsyncJob, idx : Int32, value : Double) -> Unit {
  mysql_bind_double(self.handle, idx, value)
}

///|
/// Bind UTF-8 text to exec-job parameter `idx`.
fn AsyncJob::bind_string(self : AsyncJob, idx : Int32, utf8 : Bytes) -> Unit {
  mysql_bind_string(self.handle, idx, utf8)
}

///|
/// Bind raw bytes to exec-job parameter `idx`.
fn AsyncJob::bind_blob(self : AsyncJob, idx : Int32, bytes : Bytes) -> Unit {
  mysql_bind_blob(self.handle, idx, bytes)
}

///|
/// Bind an epoch-microseconds-UTC timestamp to exec-job parameter
/// `idx`.
fn AsyncJob::bind_timestamp(
  self : AsyncJob,
  idx : Int32,
  epoch_micros : Int64,
) -> Unit {
  mysql_bind_timestamp(self.handle, idx, epoch_micros)
}

///|
/// Enqueue an exec job after all `bind_*` setters have run; `rescode`
/// reports submit-time failures (the job still needs `release`).
fn AsyncJob::submit(self : AsyncJob, rescode : Ref[Int32]) -> Unit {
  mysql_exec_submit(self.handle, rescode)
}

///|
/// Column count of the stmt's current result-set metadata.
fn MysqlStmt::col_count(self : MysqlStmt) -> Int32 {
  mysql_stmt_col_count(self)
}

///|
/// UTF-8 name of result column `idx`, decoded lossily.
fn MysqlStmt::col_name(self : MysqlStmt, idx : Int32) -> String {
  @utf8.decode_lossy(mysql_stmt_col_name(self, idx)[:])
}

///|
/// Driver `kind` code of result column `idx`.
fn MysqlStmt::col_kind(self : MysqlStmt, idx : Int32) -> Int32 {
  mysql_stmt_col_kind(self, idx)
}
