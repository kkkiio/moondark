#ifndef MOONDARK_MYSQL_GLUE_H
#define MOONDARK_MYSQL_GLUE_H

#include <moonbit.h>
#include <mysql.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>

/* Shared types for the moondark MySQL C glue layer.
 *
 * One executor owns one pthread worker guarded by a mutex/condvar FIFO job
 * queue. Every call into a given MYSQL / MYSQL_STMT handle happens on that
 * worker thread; the worker must never touch MoonBit objects. All job
 * inputs are
 * deep-copied into malloc'd memory at submit time and all results are stored
 * in C buffers; getter FFI calls on the MoonBit thread copy them out after
 * the job publishes its result.
 */

typedef struct moondark_mysql_executor moondark_mysql_executor_t;
typedef struct moondark_mysql_executor_job moondark_mysql_executor_job_t;
typedef struct moondark_mysql_job moondark_mysql_job_t;
typedef struct moondark_mysql_conn moondark_mysql_conn_t;
typedef struct moondark_mysql_stmt moondark_mysql_stmt_t;
typedef struct moondark_mysql_col moondark_mysql_col_t;

struct moondark_mysql_executor_job {
  /* Must remain the first field of every concrete job. */
  moondark_mysql_executor_job_t *next;
  void (*run)(moondark_mysql_executor_job_t *job);
};

struct moondark_mysql_executor {
  moondark_mysql_executor_job_t *head;
  moondark_mysql_executor_job_t *tail;
  bool stopping;
  pthread_mutex_t mutex;
  pthread_cond_t cond;
  pthread_t worker;
};

/* Concrete job tags stored in moondark_mysql_job.kind. The tag lets generic
 * getters and the release path verify they were handed the right job. */
enum moondark_mysql_job_kind {
  MOONDARK_MYSQL_JOB_CONNECT = 1,
  MOONDARK_MYSQL_JOB_QUERY,
  MOONDARK_MYSQL_JOB_PING,
  MOONDARK_MYSQL_JOB_RESET,
  MOONDARK_MYSQL_JOB_CONN_CLOSE,
  MOONDARK_MYSQL_JOB_PREPARE,
  MOONDARK_MYSQL_JOB_EXEC,
  MOONDARK_MYSQL_JOB_FETCH,
  MOONDARK_MYSQL_JOB_STMT_CLOSE,
  MOONDARK_MYSQL_JOB_RESULT_CLOSE
};

/* Ownership handshake between the waiter (MoonBit thread) and the worker.
 * A submitted job starts RUNNING. The worker CASes RUNNING -> PUBLISHED
 * and on success notifies the waiter, which then owns and frees the job;
 * if the waiter already released the job first, its CAS made the job
 * ABANDONED, the publish CAS fails, and the worker frees the job itself.
 * Exactly one side frees each job. */
enum moondark_mysql_job_state {
  MOONDARK_MYSQL_JOB_STATE_RUNNING = 0,
  MOONDARK_MYSQL_JOB_STATE_PUBLISHED = 1,
  MOONDARK_MYSQL_JOB_STATE_ABANDONED = 2
};

struct moondark_mysql_job {
  /* Must remain the first field of every concrete job. */
  moondark_mysql_executor_job_t executor_job;
  int32_t err_no;             /* mysql_errno/mysql_stmt_errno; 0 = success */
  char sqlstate[6];           /* 5-char SQLSTATE + NUL, or "\0" */
  char *message;              /* malloc'd UTF-8 error message, or NULL */
  atomic_int state;           /* enum moondark_mysql_job_state */
  int notification;           /* job-owned dup of the waiter's pipe fd */
  /* Internal extensions, invisible to MoonBit. */
  int32_t kind;               /* enum moondark_mysql_job_kind */
  void (*destroy)(moondark_mysql_job_t *job); /* frees concrete buffers */
  int32_t submitted;          /* enqueued at least once on an executor */
  int64_t affected_rows;      /* last affected-rows, -1 when none */
  int64_t insert_id;          /* last insert id, 0 when none */
  int32_t has_result;         /* exec produced a stored result set */
};

struct moondark_mysql_conn {
  MYSQL *mysql;
  moondark_mysql_executor_t *executor;
};

struct moondark_mysql_col {
  /* Column metadata snapshot taken on the worker after store_result. */
  char *name;                 /* malloc'd UTF-8 */
  unsigned int type;          /* enum enum_field_types */
  unsigned int charsetnr;
  unsigned int flags;
  int kind;                   /* kind code per the FFI contract mapping */
};

/* Per-column fixed-length result storage backing rbinds[].buffer. */
typedef union moondark_mysql_scalar {
  int64_t i64;
  double dbl;
  int8_t i8;                  /* TINY params: single byte, endian-safe */
  MYSQL_TIME tm;
} moondark_mysql_scalar_t;

/* Per-parameter owned storage backing pbinds[].buffer. */
typedef struct moondark_mysql_param {
  moondark_mysql_scalar_t v;  /* scalar slot for int/bool/double/timestamp */
  char *str;                  /* malloc'd bytes for string/blob, or NULL */
  unsigned long str_len;
  my_bool is_null;
} moondark_mysql_param_t;

struct moondark_mysql_stmt {
  MYSQL_STMT *stmt;
  moondark_mysql_conn_t *conn;
  int ncols;
  moondark_mysql_col_t *cols; /* filled by the exec job */
  MYSQL_BIND *rbinds;         /* result-column bind array */
  unsigned long *lengths;     /* per-col length */
  my_bool *is_nulls;          /* per-col is_null */
  my_bool *errors;            /* per-col truncation/error flag */
  moondark_mysql_scalar_t *scalars; /* fixed-length col buffers */
  int nparams;                /* mysql_stmt_param_count snapshot */
  MYSQL_BIND *pbinds;         /* parameter bind array */
  moondark_mysql_param_t *params;
};

/* ---- internal helpers shared by the .c files ---- */

bool
moondark_mysql_executor_submit(
  moondark_mysql_executor_t *executor,
  moondark_mysql_executor_job_t *job
);

bool
moondark_mysql_job_initialize(
  moondark_mysql_job_t *job,
  int notification,
  int32_t *rescode
);

bool
moondark_mysql_job_submit(
  moondark_mysql_job_t *job,
  moondark_mysql_executor_t *executor,
  int notification,
  void (*run)(moondark_mysql_executor_job_t *job),
  int32_t *rescode
);

void
moondark_mysql_job_capture_error(moondark_mysql_job_t *job, MYSQL *mysql);

void
moondark_mysql_job_capture_stmt_error(
  moondark_mysql_job_t *job,
  MYSQL_STMT *stmt
);

void
moondark_mysql_job_capture_oom(moondark_mysql_job_t *job);

void
moondark_mysql_job_capture_code(
  moondark_mysql_job_t *job,
  int32_t err_no,
  const char *sqlstate,
  const char *message
);

void
moondark_mysql_job_publish_result(moondark_mysql_job_t *job);

bool
moondark_mysql_job_result_is_published(moondark_mysql_job_t *job);

void
moondark_mysql_job_dispose(moondark_mysql_job_t *job);

/* Free the job and its payload; called on whichever thread owns it. */
void
moondark_mysql_job_reclaim(moondark_mysql_job_t *job);

/* ---- exported: library and executor ---- */

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_library_init(void);

MOONBIT_FFI_EXPORT
moondark_mysql_executor_t *
moondark_mysql_executor_create(int32_t *rescode);

MOONBIT_FFI_EXPORT
void
moondark_mysql_executor_release(moondark_mysql_executor_t *executor);

/* ---- exported: generic job accessors ---- */

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_job_acquire_result(moondark_mysql_job_t *job);

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_job_errno(moondark_mysql_job_t *job);

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moondark_mysql_job_sqlstate(moondark_mysql_job_t *job);

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moondark_mysql_job_message(moondark_mysql_job_t *job);

MOONBIT_FFI_EXPORT
void
moondark_mysql_job_release(moondark_mysql_job_t *job);

/* ---- exported: connect job ---- */

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_connect_job(
  moondark_mysql_executor_t *executor,
  moonbit_bytes_t host,
  int32_t port,
  moonbit_bytes_t user,
  moonbit_bytes_t password,
  moonbit_bytes_t database,
  int notification,
  int32_t *rescode
);

MOONBIT_FFI_EXPORT
moondark_mysql_conn_t *
moondark_mysql_job_take_conn(moondark_mysql_job_t *job);

/* ---- exported: simple command jobs ---- */

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_query_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_conn_t *conn,
  moonbit_bytes_t sql,
  int notification,
  int32_t *rescode
);

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_ping_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_conn_t *conn,
  int notification,
  int32_t *rescode
);

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_reset_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_conn_t *conn,
  int notification,
  int32_t *rescode
);

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_conn_close_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_conn_t *conn,
  int notification,
  int32_t *rescode
);

/* ---- exported: prepare job ---- */

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_prepare_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_conn_t *conn,
  moonbit_bytes_t sql,
  int notification,
  int32_t *rescode
);

MOONBIT_FFI_EXPORT
moondark_mysql_stmt_t *
moondark_mysql_job_take_stmt(moondark_mysql_job_t *job);

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_job_param_count(moondark_mysql_job_t *job);

/* ---- exported: exec job and parameter bind setters ---- */

/* Creates the job but does NOT enqueue it: the worker cannot see it until
 * moondark_mysql_exec_submit. The bind setters below fill the job's
 * parameters between creation and submission. */
MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_exec_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_stmt_t *stmt,
  int notification,
  int32_t *rescode
);

/* Enqueues a created exec job on its executor. *rescode is 0 when queued,
 * -1 on failure (bad job, already submitted, or stopping executor). */
MOONBIT_FFI_EXPORT
void
moondark_mysql_exec_submit(moondark_mysql_job_t *job, int32_t *rescode);

/* The bind setters take the exec job as their first argument and must be
 * called between moondark_mysql_exec_job and moondark_mysql_exec_submit,
 * on the MoonBit thread only. */
MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_null(moondark_mysql_job_t *job, int32_t idx);

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_int64(moondark_mysql_job_t *job, int32_t idx, int64_t v);

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_bool(moondark_mysql_job_t *job, int32_t idx, int32_t v);

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_double(moondark_mysql_job_t *job, int32_t idx, double v);

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_string(
  moondark_mysql_job_t *job,
  int32_t idx,
  moonbit_bytes_t utf8
);

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_blob(
  moondark_mysql_job_t *job,
  int32_t idx,
  moonbit_bytes_t b
);

MOONBIT_FFI_EXPORT
void
moondark_mysql_bind_timestamp(
  moondark_mysql_job_t *job,
  int32_t idx,
  int64_t epoch_micros_utc
);

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_job_has_result(moondark_mysql_job_t *job);

MOONBIT_FFI_EXPORT
int64_t
moondark_mysql_job_affected_rows(moondark_mysql_job_t *job);

MOONBIT_FFI_EXPORT
int64_t
moondark_mysql_job_insert_id(moondark_mysql_job_t *job);

/* ---- exported: result column metadata (on the stmt wrapper) ---- */

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_stmt_col_count(moondark_mysql_stmt_t *stmt);

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moondark_mysql_stmt_col_name(moondark_mysql_stmt_t *stmt, int32_t idx);

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_stmt_col_kind(moondark_mysql_stmt_t *stmt, int32_t idx);

/* ---- exported: fetch job (one row per job) ---- */

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_fetch_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_stmt_t *stmt,
  int notification,
  int32_t *rescode
);

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_job_has_row(moondark_mysql_job_t *job);

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_job_col_is_null(moondark_mysql_job_t *job, int32_t idx);

MOONBIT_FFI_EXPORT
int64_t
moondark_mysql_job_col_i64(moondark_mysql_job_t *job, int32_t idx);

MOONBIT_FFI_EXPORT
double
moondark_mysql_job_col_double(moondark_mysql_job_t *job, int32_t idx);

MOONBIT_FFI_EXPORT
int64_t
moondark_mysql_job_col_time_micros(moondark_mysql_job_t *job, int32_t idx);

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moondark_mysql_job_col_bytes(moondark_mysql_job_t *job, int32_t idx);

/* ---- exported: result close job (releases a stmt's buffered result
 * set without closing the statement, for cached-statement reuse) ---- */

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_result_close_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_stmt_t *stmt,
  int notification,
  int32_t *rescode
);

/* ---- exported: stmt close job ---- */

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_stmt_close_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_stmt_t *stmt,
  int notification,
  int32_t *rescode
);

#endif
