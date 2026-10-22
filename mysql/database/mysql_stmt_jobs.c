#define _GNU_SOURCE /* timegm */

#include "mysql_glue.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ---------- column kind mapping (contract §列类型映射) ---------- */

static int
moondark_mysql_compute_col_kind(const MYSQL_FIELD *field) {
  switch (field->type) {
  case MYSQL_TYPE_TINY:
  case MYSQL_TYPE_SHORT:
  case MYSQL_TYPE_LONG:
  case MYSQL_TYPE_INT24:
  case MYSQL_TYPE_LONGLONG:
  case MYSQL_TYPE_YEAR:
    return 1; /* Int64 */
  case MYSQL_TYPE_FLOAT:
  case MYSQL_TYPE_DOUBLE:
    return 2; /* Double */
  case MYSQL_TYPE_DATE:
  case MYSQL_TYPE_DATETIME:
  case MYSQL_TYPE_TIMESTAMP:
    return 5; /* Timestamp, bound as MYSQL_TIME */
  case MYSQL_TYPE_TINY_BLOB:
  case MYSQL_TYPE_MEDIUM_BLOB:
  case MYSQL_TYPE_LONG_BLOB:
  case MYSQL_TYPE_BLOB:
    /* charset 63 (binary) is a real BLOB; anything else is TEXT. */
    return field->charsetnr == 63 ? 4 : 3;
  case MYSQL_TYPE_VAR_STRING:
  case MYSQL_TYPE_STRING:
  case MYSQL_TYPE_VARCHAR:
  case MYSQL_TYPE_ENUM:
  case MYSQL_TYPE_SET:
  case MYSQL_TYPE_JSON:
  case MYSQL_TYPE_DECIMAL:
  case MYSQL_TYPE_NEWDECIMAL:
  case MYSQL_TYPE_TIME:
    return 3; /* String (UTF-8) */
  default:
    /* BIT, GEOMETRY and anything unrecognized fall back to Bytes. */
    return 4;
  }
}

/* ---------- stmt wrapper memory management ---------- */

static void
moondark_mysql_stmt_free_result_meta(moondark_mysql_stmt_t *stmt) {
  if (stmt->cols) {
    for (int i = 0; i < stmt->ncols; i++) {
      free(stmt->cols[i].name);
    }
  }
  free(stmt->cols);
  free(stmt->rbinds);
  free(stmt->lengths);
  free(stmt->is_nulls);
  free(stmt->errors);
  free(stmt->scalars);
  stmt->ncols = 0;
  stmt->cols = NULL;
  stmt->rbinds = NULL;
  stmt->lengths = NULL;
  stmt->is_nulls = NULL;
  stmt->errors = NULL;
  stmt->scalars = NULL;
}

/* Frees every owned buffer inside the wrapper and the wrapper itself.
 * The caller closes MYSQL_STMT first when needed (worker thread only). */
static void
moondark_mysql_stmt_free_wrapper(moondark_mysql_stmt_t *stmt) {
  if (!stmt) {
    return;
  }
  moondark_mysql_stmt_free_result_meta(stmt);
  if (stmt->params) {
    for (int i = 0; i < stmt->nparams; i++) {
      free(stmt->params[i].str);
    }
  }
  free(stmt->params);
  free(stmt->pbinds);
  free(stmt);
}

/* Closes a prepared stmt on the executor's worker thread. Used when a
 * successful prepare job is released without its stmt being taken. */
typedef struct moondark_mysql_stmt_drain {
  moondark_mysql_executor_job_t executor_job;
  moondark_mysql_stmt_t *stmt;
} moondark_mysql_stmt_drain_t;

static void
moondark_mysql_run_stmt_drain(moondark_mysql_executor_job_t *executor_job) {
  moondark_mysql_stmt_drain_t *drain =
    (moondark_mysql_stmt_drain_t *)executor_job;
  mysql_stmt_close(drain->stmt->stmt);
  moondark_mysql_stmt_free_wrapper(drain->stmt);
  free(drain);
}

static void
moondark_mysql_drain_stmt(moondark_mysql_stmt_t *stmt) {
  if (!stmt) {
    return;
  }
  moondark_mysql_stmt_drain_t *drain = calloc(1, sizeof(*drain));
  if (drain && stmt->conn && stmt->conn->executor) {
    drain->stmt = stmt;
    drain->executor_job.next = NULL;
    drain->executor_job.run = moondark_mysql_run_stmt_drain;
    if (moondark_mysql_executor_submit(
          stmt->conn->executor,
          &drain->executor_job
        )) {
      return;
    }
  }
  /* The executor is gone or stopping: MYSQL_STMT is released by the next
   * mysql_close on the connection; free only our own memory. */
  free(drain);
  moondark_mysql_stmt_free_wrapper(stmt);
}

/* ---------- prepare job ---------- */

typedef struct moondark_mysql_prepare_job {
  moondark_mysql_job_t job;
  moondark_mysql_conn_t *conn;
  char *sql;
  unsigned long sql_length;
  int32_t param_count;
  moondark_mysql_stmt_t *stmt;
} moondark_mysql_prepare_job_t;

static void
moondark_mysql_run_prepare_job(moondark_mysql_executor_job_t *executor_job) {
  moondark_mysql_prepare_job_t *prepare_job =
    (moondark_mysql_prepare_job_t *)executor_job;
  moondark_mysql_job_t *job = &prepare_job->job;
  MYSQL *mysql = prepare_job->conn->mysql;
  MYSQL_STMT *stmt = mysql_stmt_init(mysql);
  if (!stmt) {
    moondark_mysql_job_capture_error(job, mysql);
    if (job->err_no == 0) {
      moondark_mysql_job_capture_oom(job);
    }
  } else if (mysql_stmt_prepare(
               stmt,
               prepare_job->sql,
               prepare_job->sql_length
             )) {
    moondark_mysql_job_capture_stmt_error(job, stmt);
    mysql_stmt_close(stmt);
  } else {
    moondark_mysql_stmt_t *wrapper = calloc(1, sizeof(*wrapper));
    if (!wrapper) {
      moondark_mysql_job_capture_oom(job);
      mysql_stmt_close(stmt);
    } else {
      unsigned long nparams = mysql_stmt_param_count(stmt);
      wrapper->stmt = stmt;
      wrapper->conn = prepare_job->conn;
      wrapper->nparams = (int)nparams;
      prepare_job->param_count = (int32_t)nparams;
      if (nparams > 0) {
        wrapper->pbinds = calloc(nparams, sizeof(*wrapper->pbinds));
        wrapper->params = calloc(nparams, sizeof(*wrapper->params));
        if (!wrapper->pbinds || !wrapper->params) {
          moondark_mysql_job_capture_oom(job);
          moondark_mysql_stmt_free_wrapper(wrapper);
          mysql_stmt_close(stmt);
          wrapper = NULL;
        }
      }
      if (wrapper) {
        prepare_job->stmt = wrapper;
      }
    }
  }
  free(prepare_job->sql);
  prepare_job->sql = NULL;
  moondark_mysql_job_publish_result(job);
}

static void
moondark_mysql_prepare_job_destroy(moondark_mysql_job_t *job) {
  moondark_mysql_prepare_job_t *prepare_job =
    (moondark_mysql_prepare_job_t *)job;
  free(prepare_job->sql);
  prepare_job->sql = NULL;
  if (prepare_job->stmt) {
    /* Success but the stmt was never taken: close it on the worker. */
    moondark_mysql_drain_stmt(prepare_job->stmt);
    prepare_job->stmt = NULL;
  }
}

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_prepare_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_conn_t *conn,
  moonbit_bytes_t sql,
  int notification,
  int32_t *rescode
) {
  *rescode = 0;
  if (!executor || !conn || !conn->mysql) {
    *rescode = -1;
    return NULL;
  }
  moondark_mysql_prepare_job_t *prepare_job =
    calloc(1, sizeof(*prepare_job));
  if (!prepare_job) {
    *rescode = -1;
    return NULL;
  }
  int32_t sql_length = Moonbit_array_length(sql);
  prepare_job->sql = malloc((size_t)sql_length + 1);
  if (!prepare_job->sql) {
    free(prepare_job);
    *rescode = -1;
    return NULL;
  }
  memcpy(prepare_job->sql, sql, (size_t)sql_length);
  prepare_job->sql[sql_length] = '\0';
  prepare_job->sql_length = (unsigned long)sql_length;
  prepare_job->conn = conn;
  prepare_job->param_count = -1;
  prepare_job->job.kind = MOONDARK_MYSQL_JOB_PREPARE;
  prepare_job->job.destroy = moondark_mysql_prepare_job_destroy;
  if (!moondark_mysql_job_submit(
        &prepare_job->job,
        executor,
        notification,
        moondark_mysql_run_prepare_job,
        rescode
      )) {
    free(prepare_job->sql);
    free(prepare_job);
    return NULL;
  }
  return &prepare_job->job;
}

MOONBIT_FFI_EXPORT
moondark_mysql_stmt_t *
moondark_mysql_job_take_stmt(moondark_mysql_job_t *job) {
  if (!job ||
      job->kind != MOONDARK_MYSQL_JOB_PREPARE ||
      !moondark_mysql_job_result_is_published(job) ||
      job->err_no != 0) {
    return NULL;
  }
  moondark_mysql_prepare_job_t *prepare_job =
    (moondark_mysql_prepare_job_t *)job;
  moondark_mysql_stmt_t *stmt = prepare_job->stmt;
  prepare_job->stmt = NULL;
  return stmt;
}

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_job_param_count(moondark_mysql_job_t *job) {
  if (!job ||
      job->kind != MOONDARK_MYSQL_JOB_PREPARE ||
      !moondark_mysql_job_result_is_published(job)) {
    return -1;
  }
  moondark_mysql_prepare_job_t *prepare_job =
    (moondark_mysql_prepare_job_t *)job;
  return prepare_job->param_count;
}

/* ---------- exec job ---------- */

typedef struct moondark_mysql_exec_job {
  moondark_mysql_job_t job;
  moondark_mysql_stmt_t *stmt;
  moondark_mysql_executor_t *executor; /* used by exec_submit */
  int bound;                         /* params filled via bind setters */
} moondark_mysql_exec_job_t;

static void
moondark_mysql_run_exec_job(moondark_mysql_executor_job_t *executor_job) {
  moondark_mysql_exec_job_t *exec_job =
    (moondark_mysql_exec_job_t *)executor_job;
  moondark_mysql_job_t *job = &exec_job->job;
  moondark_mysql_stmt_t *wrapper = exec_job->stmt;
  MYSQL_STMT *stmt = wrapper->stmt;
  /* Release a buffered result left by a previous execution of this
   * (possibly cached) statement whose Rows was never closed, then drop
   * its stale metadata. Both are no-ops when nothing is buffered. */
  mysql_stmt_free_result(stmt);
  moondark_mysql_stmt_free_result_meta(wrapper);
  if (exec_job->bound < wrapper->nparams) {
    /* The job was submitted before every parameter slot was bound.
     * CR_PARAMS_NOT_BOUND (2031), a client-side error. */
    moondark_mysql_job_capture_code(
      job,
      2031,
      "HY000",
      "statement submitted with unbound parameters"
    );
  } else if (wrapper->nparams > 0 &&
      mysql_stmt_bind_param(stmt, wrapper->pbinds)) {
    moondark_mysql_job_capture_stmt_error(job, stmt);
  } else if (mysql_stmt_execute(stmt)) {
    moondark_mysql_job_capture_stmt_error(job, stmt);
  } else {
    job->affected_rows = (int64_t)mysql_stmt_affected_rows(stmt);
    job->insert_id = (int64_t)mysql_stmt_insert_id(stmt);
    unsigned int ncols = mysql_stmt_field_count(stmt);
    if (ncols > 0) {
      if (mysql_stmt_store_result(stmt)) {
        moondark_mysql_job_capture_stmt_error(job, stmt);
      } else {
        MYSQL_RES *meta = mysql_stmt_result_metadata(stmt);
        if (!meta) {
          moondark_mysql_job_capture_oom(job);
        } else {
          MYSQL_FIELD *fields = mysql_fetch_fields(meta);
          wrapper->ncols = (int)ncols;
          wrapper->cols = calloc(ncols, sizeof(*wrapper->cols));
          wrapper->rbinds = calloc(ncols, sizeof(*wrapper->rbinds));
          wrapper->lengths = calloc(ncols, sizeof(*wrapper->lengths));
          wrapper->is_nulls = calloc(ncols, sizeof(*wrapper->is_nulls));
          wrapper->errors = calloc(ncols, sizeof(*wrapper->errors));
          wrapper->scalars = calloc(ncols, sizeof(*wrapper->scalars));
          if (!wrapper->cols || !wrapper->rbinds || !wrapper->lengths ||
              !wrapper->is_nulls || !wrapper->errors || !wrapper->scalars) {
            moondark_mysql_job_capture_oom(job);
          } else {
            for (unsigned int i = 0; i < ncols && job->err_no == 0; i++) {
              moondark_mysql_col_t *col = &wrapper->cols[i];
              col->name = strdup(fields[i].name ? fields[i].name : "");
              if (!col->name) {
                moondark_mysql_job_capture_oom(job);
                break;
              }
              col->type = (unsigned int)fields[i].type;
              col->charsetnr = fields[i].charsetnr;
              col->flags = fields[i].flags;
              col->kind = moondark_mysql_compute_col_kind(&fields[i]);
              MYSQL_BIND *rbind = &wrapper->rbinds[i];
              rbind->length = &wrapper->lengths[i];
              rbind->is_null = &wrapper->is_nulls[i];
              rbind->error = &wrapper->errors[i];
              switch (col->kind) {
              case 1: /* Int64 */
                rbind->buffer_type = MYSQL_TYPE_LONGLONG;
                rbind->buffer = &wrapper->scalars[i].i64;
                rbind->buffer_length = sizeof(int64_t);
                rbind->is_unsigned =
                  (fields[i].flags & UNSIGNED_FLAG) != 0;
                break;
              case 2: /* Double */
                rbind->buffer_type = MYSQL_TYPE_DOUBLE;
                rbind->buffer = &wrapper->scalars[i].dbl;
                rbind->buffer_length = sizeof(double);
                break;
              case 5: /* Timestamp */
                rbind->buffer_type = MYSQL_TYPE_DATETIME;
                rbind->buffer = &wrapper->scalars[i].tm;
                rbind->buffer_length = sizeof(MYSQL_TIME);
                break;
              default:
                /* Variable-length: fetch writes only *length; the row
                 * payload is pulled per column by mysql_stmt_fetch_column. */
                rbind->buffer_type = MYSQL_TYPE_STRING;
                rbind->buffer = NULL;
                rbind->buffer_length = 0;
                break;
              }
            }
            if (job->err_no == 0 &&
                mysql_stmt_bind_result(stmt, wrapper->rbinds)) {
              moondark_mysql_job_capture_stmt_error(job, stmt);
            }
            if (job->err_no == 0) {
              job->has_result = 1;
            }
          }
          mysql_free_result(meta);
          if (job->err_no != 0) {
            moondark_mysql_stmt_free_result_meta(wrapper);
          }
        }
      }
    }
  }
  moondark_mysql_job_publish_result(job);
}

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_exec_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_stmt_t *stmt,
  int notification,
  int32_t *rescode
) {
  *rescode = 0;
  if (!executor || !stmt || !stmt->stmt) {
    *rescode = -1;
    return NULL;
  }
  moondark_mysql_exec_job_t *exec_job = calloc(1, sizeof(*exec_job));
  if (!exec_job) {
    *rescode = -1;
    return NULL;
  }
  exec_job->stmt = stmt;
  exec_job->executor = executor;
  exec_job->job.kind = MOONDARK_MYSQL_JOB_EXEC;
  /* The job is created but NOT enqueued: bind setters fill its parameters
   * first, then moondark_mysql_exec_submit hands it to the worker. */
  if (!moondark_mysql_job_initialize(
        &exec_job->job,
        notification,
        rescode
      )) {
    free(exec_job);
    return NULL;
  }
  exec_job->job.executor_job.run = moondark_mysql_run_exec_job;
  return &exec_job->job;
}

MOONBIT_FFI_EXPORT
void
moondark_mysql_exec_submit(
  moondark_mysql_job_t *job,
  int32_t *rescode
) {
  *rescode = 0;
  if (!job ||
      job->kind != MOONDARK_MYSQL_JOB_EXEC ||
      job->submitted) {
    *rescode = -1;
    return;
  }
  moondark_mysql_exec_job_t *exec_job =
    (moondark_mysql_exec_job_t *)job;
  if (!moondark_mysql_executor_submit(
        exec_job->executor,
        &job->executor_job
      )) {
    *rescode = -1;
    return;
  }
  job->submitted = 1;
}

/* ---------- parameter bind setters ---------- */

/* The first argument must be the exec job returned by
 * moondark_mysql_exec_job. Binds after exec_submit are ignored: the
 * worker may already be running the job. */
static moondark_mysql_exec_job_t *
moondark_mysql_bind_target(moondark_mysql_job_t *job) {
  if (!job ||
      job->kind != MOONDARK_MYSQL_JOB_EXEC ||
      job->submitted) {
    return NULL;
  }
  moondark_mysql_exec_job_t *exec_job =
    (moondark_mysql_exec_job_t *)job;
  return exec_job->stmt ? exec_job : NULL;
}

static int
moondark_mysql_bind_slot(
  moondark_mysql_stmt_t *stmt,
  int32_t idx,
  MYSQL_BIND **bind_out,
  moondark_mysql_param_t **param_out
) {
  if (!stmt || idx < 0 || idx >= stmt->nparams) {
    return 0;
  }
  MYSQL_BIND *bind = &stmt->pbinds[idx];
  moondark_mysql_param_t *param = &stmt->params[idx];
  memset(bind, 0, sizeof(*bind));
  param->is_null = 0;
  free(param->str);
  param->str = NULL;
  param->str_len = 0;
  bind->is_null = &param->is_null;
  *bind_out = bind;
  *param_out = param;
  return 1;
}

static void
moondark_mysql_bind_bytes(
  moondark_mysql_job_t *job,
  int32_t idx,
  moonbit_bytes_t bytes,
  enum enum_field_types type
) {
  moondark_mysql_exec_job_t *exec_job =
    moondark_mysql_bind_target(job);
  if (!exec_job) {
    return;
  }
  MYSQL_BIND *bind = NULL;
  moondark_mysql_param_t *param = NULL;
  if (!moondark_mysql_bind_slot(exec_job->stmt, idx, &bind, &param)) {
    return;
  }
  int32_t length = Moonbit_array_length(bytes);
  param->str = malloc((size_t)length + 1);
  if (!param->str) {
    return;
  }
  if (length > 0) {
    memcpy(param->str, bytes, (size_t)length);
  }
  param->str[length] = '\0';
  param->str_len = (unsigned long)length;
  bind->buffer_type = type;
  bind->buffer = param->str;
  bind->buffer_length = (unsigned long)length;
  bind->length = &param->str_len;
  exec_job->bound++;
}

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_null(moondark_mysql_job_t *job, int32_t idx) {
  moondark_mysql_exec_job_t *exec_job =
    moondark_mysql_bind_target(job);
  if (!exec_job) {
    return;
  }
  MYSQL_BIND *bind = NULL;
  moondark_mysql_param_t *param = NULL;
  if (!moondark_mysql_bind_slot(exec_job->stmt, idx, &bind, &param)) {
    return;
  }
  param->is_null = 1;
  bind->buffer_type = MYSQL_TYPE_NULL;
  exec_job->bound++;
}

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_int64(
  moondark_mysql_job_t *job,
  int32_t idx,
  int64_t v
) {
  moondark_mysql_exec_job_t *exec_job =
    moondark_mysql_bind_target(job);
  if (!exec_job) {
    return;
  }
  MYSQL_BIND *bind = NULL;
  moondark_mysql_param_t *param = NULL;
  if (!moondark_mysql_bind_slot(exec_job->stmt, idx, &bind, &param)) {
    return;
  }
  param->v.i64 = v;
  bind->buffer_type = MYSQL_TYPE_LONGLONG;
  bind->buffer = &param->v.i64;
  bind->buffer_length = sizeof(int64_t);
  exec_job->bound++;
}

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_bool(
  moondark_mysql_job_t *job,
  int32_t idx,
  int32_t v
) {
  moondark_mysql_exec_job_t *exec_job =
    moondark_mysql_bind_target(job);
  if (!exec_job) {
    return;
  }
  MYSQL_BIND *bind = NULL;
  moondark_mysql_param_t *param = NULL;
  if (!moondark_mysql_bind_slot(exec_job->stmt, idx, &bind, &param)) {
    return;
  }
  param->v.i8 = v ? 1 : 0;
  bind->buffer_type = MYSQL_TYPE_TINY;
  bind->buffer = &param->v.i8;
  bind->buffer_length = 1;
  exec_job->bound++;
}

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_double(
  moondark_mysql_job_t *job,
  int32_t idx,
  double v
) {
  moondark_mysql_exec_job_t *exec_job =
    moondark_mysql_bind_target(job);
  if (!exec_job) {
    return;
  }
  MYSQL_BIND *bind = NULL;
  moondark_mysql_param_t *param = NULL;
  if (!moondark_mysql_bind_slot(exec_job->stmt, idx, &bind, &param)) {
    return;
  }
  param->v.dbl = v;
  bind->buffer_type = MYSQL_TYPE_DOUBLE;
  bind->buffer = &param->v.dbl;
  bind->buffer_length = sizeof(double);
  exec_job->bound++;
}

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_string(
  moondark_mysql_job_t *job,
  int32_t idx,
  moonbit_bytes_t utf8
) {
  moondark_mysql_bind_bytes(job, idx, utf8, MYSQL_TYPE_STRING);
}

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_blob(
  moondark_mysql_job_t *job,
  int32_t idx,
  moonbit_bytes_t b
) {
  moondark_mysql_bind_bytes(job, idx, b, MYSQL_TYPE_BLOB);
}

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_timestamp(
  moondark_mysql_job_t *job,
  int32_t idx,
  int64_t epoch_micros_utc
) {
  moondark_mysql_exec_job_t *exec_job =
    moondark_mysql_bind_target(job);
  if (!exec_job) {
    return;
  }
  MYSQL_BIND *bind = NULL;
  moondark_mysql_param_t *param = NULL;
  if (!moondark_mysql_bind_slot(exec_job->stmt, idx, &bind, &param)) {
    return;
  }
  int64_t seconds = epoch_micros_utc / 1000000;
  int64_t micros = epoch_micros_utc % 1000000;
  if (micros < 0) {
    micros += 1000000;
    seconds -= 1;
  }
  time_t t = (time_t)seconds;
  struct tm tmv;
  if (gmtime_r(&t, &tmv)) {
    memset(&param->v.tm, 0, sizeof(param->v.tm));
    param->v.tm.year = (unsigned int)tmv.tm_year + 1900;
    param->v.tm.month = (unsigned int)tmv.tm_mon + 1;
    param->v.tm.day = (unsigned int)tmv.tm_mday;
    param->v.tm.hour = (unsigned int)tmv.tm_hour;
    param->v.tm.minute = (unsigned int)tmv.tm_min;
    param->v.tm.second = (unsigned int)tmv.tm_sec;
    param->v.tm.second_part = (unsigned long)micros;
    param->v.tm.time_type = MYSQL_TIMESTAMP_DATETIME;
  }
  bind->buffer_type = MYSQL_TYPE_DATETIME;
  bind->buffer = &param->v.tm;
  bind->buffer_length = sizeof(MYSQL_TIME);
  exec_job->bound++;
}

/* ---------- result column metadata getters ---------- */

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_stmt_col_count(moondark_mysql_stmt_t *stmt) {
  if (!stmt || !stmt->stmt) {
    return 0;
  }
  return stmt->ncols;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moondark_mysql_stmt_col_name(moondark_mysql_stmt_t *stmt, int32_t idx) {
  if (!stmt || !stmt->stmt ||
      idx < 0 || idx >= stmt->ncols || !stmt->cols[idx].name) {
    return moonbit_make_bytes(0, 0);
  }
  size_t length = strlen(stmt->cols[idx].name);
  if (length > INT32_MAX) {
    length = INT32_MAX;
  }
  moonbit_bytes_t name = moonbit_make_bytes((int32_t)length, 0);
  if (length > 0) {
    memcpy(name, stmt->cols[idx].name, length);
  }
  return name;
}

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_stmt_col_kind(moondark_mysql_stmt_t *stmt, int32_t idx) {
  if (!stmt || !stmt->stmt ||
      idx < 0 || idx >= stmt->ncols) {
    return 4; /* unknown fallback: Bytes */
  }
  return stmt->cols[idx].kind;
}

/* ---------- fetch job (one row) ---------- */

typedef struct moondark_mysql_fetch_val {
  my_bool is_null;
  int64_t i64;
  double dbl;
  MYSQL_TIME tm;
  unsigned char *bytes; /* malloc'd copy for string/blob columns */
  unsigned long length;
} moondark_mysql_fetch_val_t;

typedef struct moondark_mysql_fetch_job {
  moondark_mysql_job_t job;
  moondark_mysql_stmt_t *stmt;
  int32_t has_row;
  int nvals; /* stmt->ncols snapshot: stmt may be closed before release */
  moondark_mysql_fetch_val_t *vals;
} moondark_mysql_fetch_job_t;

static int
moondark_mysql_col_is_fixed(int kind) {
  return kind == 1 || kind == 2 || kind == 5;
}

static void
moondark_mysql_run_fetch_job(moondark_mysql_executor_job_t *executor_job) {
  moondark_mysql_fetch_job_t *fetch_job =
    (moondark_mysql_fetch_job_t *)executor_job;
  moondark_mysql_job_t *job = &fetch_job->job;
  moondark_mysql_stmt_t *wrapper = fetch_job->stmt;
  MYSQL_STMT *stmt = wrapper->stmt;
  /* Variable-column rbinds may still point at buffers owned by a previous
   * fetch job; detach them so this fetch only reports lengths. */
  for (int i = 0; i < wrapper->ncols; i++) {
    if (!moondark_mysql_col_is_fixed(wrapper->cols[i].kind)) {
      wrapper->rbinds[i].buffer = NULL;
      wrapper->rbinds[i].buffer_length = 0;
    }
  }
  int rc = mysql_stmt_fetch(stmt);
  if (rc == MYSQL_NO_DATA) {
    fetch_job->has_row = 0;
  } else if (rc == 1 || mysql_stmt_errno(stmt) != 0) {
    moondark_mysql_job_capture_stmt_error(job, stmt);
    if (job->err_no == 0) {
      /* rc == 1 without a stmt errno: report a generic client error. */
      job->err_no = 2000; /* CR_UNKNOWN_ERROR */
      memcpy(job->sqlstate, "HY000", 6);
      job->message = strdup("mysql_stmt_fetch failed");
    }
  } else {
    fetch_job->has_row = 1;
    for (int i = 0; i < wrapper->ncols && job->err_no == 0; i++) {
      moondark_mysql_fetch_val_t *val = &fetch_job->vals[i];
      val->is_null = wrapper->is_nulls[i];
      if (val->is_null) {
        continue;
      }
      int kind = wrapper->cols[i].kind;
      if (kind == 1) {
        val->i64 = wrapper->scalars[i].i64;
      } else if (kind == 2) {
        val->dbl = wrapper->scalars[i].dbl;
      } else if (kind == 5) {
        val->tm = wrapper->scalars[i].tm;
      } else {
        unsigned long length = wrapper->lengths[i];
        unsigned char *buffer = malloc(length == 0 ? 1 : length);
        if (!buffer) {
          moondark_mysql_job_capture_oom(job);
          break;
        }
        wrapper->rbinds[i].buffer = buffer;
        wrapper->rbinds[i].buffer_length = length;
        int fetch_rc =
          mysql_stmt_fetch_column(stmt, &wrapper->rbinds[i], i, 0);
        wrapper->rbinds[i].buffer = NULL;
        wrapper->rbinds[i].buffer_length = 0;
        if (fetch_rc) {
          free(buffer);
          moondark_mysql_job_capture_stmt_error(job, stmt);
          break;
        }
        val->bytes = buffer;
        val->length = length;
      }
    }
  }
  moondark_mysql_job_publish_result(job);
}

static void
moondark_mysql_fetch_job_destroy(moondark_mysql_job_t *job) {
  moondark_mysql_fetch_job_t *fetch_job =
    (moondark_mysql_fetch_job_t *)job;
  if (fetch_job->vals) {
    for (int i = 0; i < fetch_job->nvals; i++) {
      free(fetch_job->vals[i].bytes);
    }
  }
  free(fetch_job->vals);
  fetch_job->vals = NULL;
}

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_fetch_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_stmt_t *stmt,
  int notification,
  int32_t *rescode
) {
  *rescode = 0;
  if (!executor || !stmt || !stmt->stmt) {
    *rescode = -1;
    return NULL;
  }
  moondark_mysql_fetch_job_t *fetch_job = calloc(1, sizeof(*fetch_job));
  if (!fetch_job) {
    *rescode = -1;
    return NULL;
  }
  fetch_job->nvals = stmt->ncols;
  if (stmt->ncols > 0) {
    fetch_job->vals = calloc(
      (size_t)stmt->ncols,
      sizeof(*fetch_job->vals)
    );
    if (!fetch_job->vals) {
      free(fetch_job);
      *rescode = -1;
      return NULL;
    }
  }
  fetch_job->stmt = stmt;
  fetch_job->job.kind = MOONDARK_MYSQL_JOB_FETCH;
  fetch_job->job.destroy = moondark_mysql_fetch_job_destroy;
  if (!moondark_mysql_job_submit(
        &fetch_job->job,
        executor,
        notification,
        moondark_mysql_run_fetch_job,
        rescode
      )) {
    free(fetch_job->vals);
    free(fetch_job);
    return NULL;
  }
  return &fetch_job->job;
}

static moondark_mysql_fetch_val_t *
moondark_mysql_fetch_val_at(
  moondark_mysql_job_t *job,
  int32_t idx
) {
  if (!job ||
      job->kind != MOONDARK_MYSQL_JOB_FETCH ||
      !moondark_mysql_job_result_is_published(job)) {
    return NULL;
  }
  moondark_mysql_fetch_job_t *fetch_job =
    (moondark_mysql_fetch_job_t *)job;
  if (!fetch_job->has_row || !fetch_job->vals ||
      idx < 0 || idx >= fetch_job->nvals) {
    return NULL;
  }
  return &fetch_job->vals[idx];
}

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_job_has_row(moondark_mysql_job_t *job) {
  if (!job ||
      job->kind != MOONDARK_MYSQL_JOB_FETCH ||
      !moondark_mysql_job_result_is_published(job)) {
    return 0;
  }
  moondark_mysql_fetch_job_t *fetch_job =
    (moondark_mysql_fetch_job_t *)job;
  return fetch_job->has_row;
}

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_job_col_is_null(moondark_mysql_job_t *job, int32_t idx) {
  moondark_mysql_fetch_val_t *val =
    moondark_mysql_fetch_val_at(job, idx);
  return val ? (int32_t)val->is_null : 1;
}

MOONBIT_FFI_EXPORT
int64_t
moondark_mysql_job_col_i64(moondark_mysql_job_t *job, int32_t idx) {
  moondark_mysql_fetch_val_t *val =
    moondark_mysql_fetch_val_at(job, idx);
  return val ? val->i64 : 0;
}

MOONBIT_FFI_EXPORT
double
moondark_mysql_job_col_double(moondark_mysql_job_t *job, int32_t idx) {
  moondark_mysql_fetch_val_t *val =
    moondark_mysql_fetch_val_at(job, idx);
  return val ? val->dbl : 0.0;
}

MOONBIT_FFI_EXPORT
int64_t
moondark_mysql_job_col_time_micros(moondark_mysql_job_t *job, int32_t idx) {
  moondark_mysql_fetch_val_t *val =
    moondark_mysql_fetch_val_at(job, idx);
  if (!val) {
    return 0;
  }
  struct tm tmv;
  memset(&tmv, 0, sizeof(tmv));
  tmv.tm_year = (int)val->tm.year - 1900;
  tmv.tm_mon = (int)val->tm.month - 1;
  tmv.tm_mday = (int)val->tm.day;
  tmv.tm_hour = (int)val->tm.hour;
  tmv.tm_min = (int)val->tm.minute;
  tmv.tm_sec = (int)val->tm.second;
  time_t seconds = timegm(&tmv);
  /* DATE columns carry a zero time part: this is midnight UTC. */
  return (int64_t)seconds * 1000000 + (int64_t)val->tm.second_part;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moondark_mysql_job_col_bytes(moondark_mysql_job_t *job, int32_t idx) {
  moondark_mysql_fetch_val_t *val =
    moondark_mysql_fetch_val_at(job, idx);
  if (!val || !val->bytes || val->length == 0) {
    return moonbit_make_bytes(0, 0);
  }
  size_t length = val->length > INT32_MAX ? INT32_MAX : val->length;
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)length, 0);
  memcpy(bytes, val->bytes, length);
  return bytes;
}

/* ---------- stmt close job ---------- */

typedef struct moondark_mysql_stmt_close_job {
  moondark_mysql_job_t job;
  moondark_mysql_stmt_t *stmt;
} moondark_mysql_stmt_close_job_t;

static void
moondark_mysql_run_stmt_close_job(
  moondark_mysql_executor_job_t *executor_job
) {
  moondark_mysql_stmt_close_job_t *close_job =
    (moondark_mysql_stmt_close_job_t *)executor_job;
  moondark_mysql_job_t *job = &close_job->job;
  moondark_mysql_stmt_t *wrapper = close_job->stmt;
  if (mysql_stmt_close(wrapper->stmt)) {
    moondark_mysql_job_capture_error(job, wrapper->conn->mysql);
  }
  wrapper->stmt = NULL;
  moondark_mysql_stmt_free_wrapper(wrapper);
  close_job->stmt = NULL;
  moondark_mysql_job_publish_result(job);
}

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_stmt_close_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_stmt_t *stmt,
  int notification,
  int32_t *rescode
) {
  *rescode = 0;
  if (!executor || !stmt || !stmt->stmt) {
    *rescode = -1;
    return NULL;
  }
  moondark_mysql_stmt_close_job_t *close_job =
    calloc(1, sizeof(*close_job));
  if (!close_job) {
    *rescode = -1;
    return NULL;
  }
  close_job->stmt = stmt;
  close_job->job.kind = MOONDARK_MYSQL_JOB_STMT_CLOSE;
  if (!moondark_mysql_job_submit(
        &close_job->job,
        executor,
        notification,
        moondark_mysql_run_stmt_close_job,
        rescode
      )) {
    free(close_job);
    return NULL;
  }
  return &close_job->job;
}

/* ---------- result close job (Rows::close without freeing the stmt) ---- */

static void
moondark_mysql_run_result_close_job(
  moondark_mysql_executor_job_t *executor_job
) {
  moondark_mysql_stmt_close_job_t *close_job =
    (moondark_mysql_stmt_close_job_t *)executor_job;
  moondark_mysql_job_t *job = &close_job->job;
  MYSQL_STMT *stmt = close_job->stmt->stmt;
  /* Releases the stored result set only: the statement stays usable and
   * the wrapper's column metadata is dropped with the next exec. */
  if (mysql_stmt_free_result(stmt)) {
    moondark_mysql_job_capture_stmt_error(job, stmt);
  }
  moondark_mysql_job_publish_result(job);
}

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_result_close_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_stmt_t *stmt,
  int notification,
  int32_t *rescode
) {
  *rescode = 0;
  if (!executor || !stmt || !stmt->stmt) {
    *rescode = -1;
    return NULL;
  }
  moondark_mysql_stmt_close_job_t *close_job =
    calloc(1, sizeof(*close_job));
  if (!close_job) {
    *rescode = -1;
    return NULL;
  }
  close_job->stmt = stmt;
  close_job->job.kind = MOONDARK_MYSQL_JOB_RESULT_CLOSE;
  if (!moondark_mysql_job_submit(
        &close_job->job,
        executor,
        notification,
        moondark_mysql_run_result_close_job,
        rescode
      )) {
    free(close_job);
    return NULL;
  }
  return &close_job->job;
}
