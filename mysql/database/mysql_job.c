#include "mysql_glue.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ---------- job lifecycle ---------- */

bool
moondark_mysql_job_initialize(
  moondark_mysql_job_t *job,
  int notification,
  int32_t *rescode
) {
  *rescode = 0;
  if (!job) {
    *rescode = -1;
    return false;
  }
  job->executor_job.next = NULL;
  job->executor_job.run = NULL;
  job->err_no = 0;
  job->sqlstate[0] = '\0';
  job->message = NULL;
  atomic_init(&job->state, MOONDARK_MYSQL_JOB_STATE_RUNNING);
  /* The caller owns `notification` and closes it right after submit, so the
   * job takes its own duplicate; otherwise the recycled fd number could be
   * written into an unrelated pipe. */
  if (notification < 0) {
    *rescode = -1;
    return false;
  }
  int duplicate = dup(notification);
  if (duplicate < 0) {
    *rescode = -1;
    return false;
  }
  (void)fcntl(duplicate, F_SETFD, fcntl(duplicate, F_GETFD) | FD_CLOEXEC);
  job->notification = duplicate;
  job->submitted = 0;
  job->affected_rows = -1;
  job->insert_id = 0;
  job->has_result = 0;
  return true;
}

bool
moondark_mysql_job_submit(
  moondark_mysql_job_t *job,
  moondark_mysql_executor_t *executor,
  int notification,
  void (*run)(moondark_mysql_executor_job_t *executor_job),
  int32_t *rescode
) {
  if (!executor) {
    *rescode = -1;
    return false;
  }
  if (!moondark_mysql_job_initialize(job, notification, rescode)) {
    return false;
  }
  job->executor_job.run = run;
  if (!moondark_mysql_executor_submit(executor, &job->executor_job)) {
    close(job->notification);
    job->notification = -1;
    *rescode = -1;
    return false;
  }
  job->submitted = 1;
  return true;
}

/* ---------- error capture ---------- */

static void
moondark_mysql_job_fill_error(
  moondark_mysql_job_t *job,
  unsigned int err_no,
  const char *sqlstate,
  const char *message
) {
  if (err_no == 0 || job->err_no != 0) {
    /* Only the first failure is recorded. */
    return;
  }
  job->err_no = (int32_t)err_no;
  if (sqlstate && strlen(sqlstate) >= 5) {
    memcpy(job->sqlstate, sqlstate, 5);
    job->sqlstate[5] = '\0';
  } else {
    job->sqlstate[0] = '\0';
  }
  free(job->message);
  job->message = NULL;
  if (message && message[0]) {
    job->message = strdup(message);
  }
}

void
moondark_mysql_job_capture_error(
  moondark_mysql_job_t *job,
  MYSQL *mysql
) {
  if (!mysql) {
    return;
  }
  moondark_mysql_job_fill_error(
    job,
    mysql_errno(mysql),
    mysql_sqlstate(mysql),
    mysql_error(mysql)
  );
}

void
moondark_mysql_job_capture_stmt_error(
  moondark_mysql_job_t *job,
  MYSQL_STMT *stmt
) {
  if (!stmt) {
    return;
  }
  moondark_mysql_job_fill_error(
    job,
    mysql_stmt_errno(stmt),
    mysql_stmt_sqlstate(stmt),
    mysql_stmt_error(stmt)
  );
}

void
moondark_mysql_job_capture_oom(moondark_mysql_job_t *job) {
  /* CR_OUT_OF_MEMORY; SQLSTATE for client-side allocation failures. */
  moondark_mysql_job_fill_error(job, 2008, "HY000", "out of memory");
}

void
moondark_mysql_job_capture_code(
  moondark_mysql_job_t *job,
  int32_t err_no,
  const char *sqlstate,
  const char *message
) {
  /* Client-side errors not reportable through a MYSQL/MYSQL_STMT handle. */
  moondark_mysql_job_fill_error(
    job,
    (unsigned int)err_no,
    sqlstate,
    message
  );
}

/* ---------- publish / dispose ---------- */

void
moondark_mysql_job_publish_result(moondark_mysql_job_t *job) {
  /* Copy the notification fd and clear it first: once the CAS below
   * succeeds the waiter owns the job and may free it at any moment, so
   * the worker must not touch the job afterwards. */
  int notification = job->notification;
  job->notification = -1;
  int expected = MOONDARK_MYSQL_JOB_STATE_RUNNING;
  if (!atomic_compare_exchange_strong_explicit(
        &job->state,
        &expected,
        MOONDARK_MYSQL_JOB_STATE_PUBLISHED,
        memory_order_release,
        memory_order_acquire
      )) {
    /* The waiter released the job before it published (the waiting
     * coroutine was cancelled): nobody listens on the pipe and nobody
     * will release the job again, so the worker reclaims it here. */
    if (notification >= 0) {
      close(notification);
    }
    moondark_mysql_job_reclaim(job);
    return;
  }
  if (notification >= 0) {
    ssize_t written;
    do {
      written = write(notification, "x", 1);
    } while (written < 0 && errno == EINTR);
    (void)written;
    close(notification);
  }
}

bool
moondark_mysql_job_result_is_published(moondark_mysql_job_t *job) {
  if (!job) {
    return false;
  }
  return atomic_load_explicit(&job->state, memory_order_acquire) ==
    MOONDARK_MYSQL_JOB_STATE_PUBLISHED;
}

void
moondark_mysql_job_dispose(moondark_mysql_job_t *job) {
  /* Close the job's own notification duplicate if it is still held (the job
   * was released without ever being published). */
  if (job->notification >= 0) {
    close(job->notification);
    job->notification = -1;
  }
  free(job->message);
  job->message = NULL;
}

/* ---------- exported accessors ---------- */

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_job_acquire_result(moondark_mysql_job_t *job) {
  return moondark_mysql_job_result_is_published(job) ? 1 : 0;
}

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_job_errno(moondark_mysql_job_t *job) {
  return job && moondark_mysql_job_result_is_published(job)
    ? job->err_no
    : -1;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moondark_mysql_job_sqlstate(moondark_mysql_job_t *job) {
  int32_t length =
    job && moondark_mysql_job_result_is_published(job) &&
      job->sqlstate[0]
    ? 5
    : 0;
  moonbit_bytes_t result = moonbit_make_bytes(length, 0);
  if (length > 0) {
    memcpy(result, job->sqlstate, 5);
  }
  return result;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t
moondark_mysql_job_message(moondark_mysql_job_t *job) {
  size_t length =
    job && moondark_mysql_job_result_is_published(job) && job->message
    ? strlen(job->message)
    : 0;
  if (length > INT32_MAX) {
    length = INT32_MAX;
  }
  moonbit_bytes_t result = moonbit_make_bytes((int32_t)length, 0);
  if (length > 0) {
    memcpy(result, job->message, length);
  }
  return result;
}

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_job_has_result(moondark_mysql_job_t *job) {
  return job && moondark_mysql_job_result_is_published(job)
    ? job->has_result
    : 0;
}

MOONBIT_FFI_EXPORT
int64_t
moondark_mysql_job_affected_rows(moondark_mysql_job_t *job) {
  return job && moondark_mysql_job_result_is_published(job)
    ? job->affected_rows
    : -1;
}

MOONBIT_FFI_EXPORT
int64_t
moondark_mysql_job_insert_id(moondark_mysql_job_t *job) {
  return job && moondark_mysql_job_result_is_published(job)
    ? job->insert_id
    : 0;
}

void
moondark_mysql_job_reclaim(moondark_mysql_job_t *job) {
  if (job->destroy) {
    job->destroy(job);
  }
  moondark_mysql_job_dispose(job);
  free(job);
}

MOONBIT_FFI_EXPORT
void
moondark_mysql_job_release(moondark_mysql_job_t *job) {
  if (!job) {
    return;
  }
  if (job->submitted) {
    /* The worker owns a queued job until it publishes. If the job is
     * still RUNNING, hand ownership to the worker by marking it
     * abandoned; if it already published, we own it and free it here. */
    int expected = MOONDARK_MYSQL_JOB_STATE_RUNNING;
    if (atomic_compare_exchange_strong_explicit(
          &job->state,
          &expected,
          MOONDARK_MYSQL_JOB_STATE_ABANDONED,
          memory_order_acq_rel,
          memory_order_acquire
        )) {
      return;
    }
  }
  /* Unsubmitted (e.g. an exec job abandoned before exec_submit) or
   * already published: the caller owns it. */
  moondark_mysql_job_reclaim(job);
}
