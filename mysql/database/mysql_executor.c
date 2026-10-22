#include "mysql_glue.h"
#include <signal.h>
#include <stdlib.h>

/* ---------- library init ---------- */

static pthread_once_t moondark_mysql_library_once = PTHREAD_ONCE_INIT;
static int moondark_mysql_library_rc = -1;

static void
moondark_mysql_library_init_once(void) {
  /* A waiter cancelled between the worker's publish CAS and its pipe
   * write has already closed the read end; without this the worker's
   * write would raise SIGPIPE and kill the process. EPIPE is handled
   * instead. */
  signal(SIGPIPE, SIG_IGN);
  moondark_mysql_library_rc = mysql_library_init(0, NULL, NULL);
}

MOONBIT_FFI_EXPORT
int32_t
moondark_mysql_library_init(void) {
  pthread_once(
    &moondark_mysql_library_once,
    moondark_mysql_library_init_once
  );
  return moondark_mysql_library_rc == 0 ? 0 : -1;
}

/* ---------- executor ---------- */

static void *moondark_mysql_worker(void *data);

static void
moondark_mysql_executor_lock(moondark_mysql_executor_t *executor) {
  pthread_mutex_lock(&executor->mutex);
}

static void
moondark_mysql_executor_unlock(moondark_mysql_executor_t *executor) {
  pthread_mutex_unlock(&executor->mutex);
}

static void
moondark_mysql_executor_wait(moondark_mysql_executor_t *executor) {
  pthread_cond_wait(&executor->cond, &executor->mutex);
}

static void
moondark_mysql_executor_wake(moondark_mysql_executor_t *executor) {
  pthread_cond_signal(&executor->cond);
}

static moondark_mysql_executor_job_t *
moondark_mysql_executor_take(moondark_mysql_executor_t *executor) {
  moondark_mysql_executor_lock(executor);
  while (!executor->head && !executor->stopping) {
    moondark_mysql_executor_wait(executor);
  }
  moondark_mysql_executor_job_t *job = executor->head;
  if (job) {
    executor->head = job->next;
    if (!executor->head) {
      executor->tail = NULL;
    }
    job->next = NULL;
  }
  moondark_mysql_executor_unlock(executor);
  return job;
}

static void *
moondark_mysql_worker(void *data) {
  moondark_mysql_executor_t *executor = data;
  mysql_thread_init();
  for (moondark_mysql_executor_job_t *job =
         moondark_mysql_executor_take(executor);
       job;
       job = moondark_mysql_executor_take(executor)) {
    job->run(job);
  }
  mysql_thread_end();
  return NULL;
}

MOONBIT_FFI_EXPORT
moondark_mysql_executor_t *
moondark_mysql_executor_create(int32_t *rescode) {
  *rescode = 0;
  moondark_mysql_executor_t *executor = calloc(1, sizeof(*executor));
  if (!executor) {
    *rescode = -1;
    return NULL;
  }
  if (pthread_mutex_init(&executor->mutex, NULL) != 0) {
    free(executor);
    *rescode = -1;
    return NULL;
  }
  if (pthread_cond_init(&executor->cond, NULL) != 0) {
    pthread_mutex_destroy(&executor->mutex);
    free(executor);
    *rescode = -1;
    return NULL;
  }
  if (pthread_create(
        &executor->worker,
        NULL,
        moondark_mysql_worker,
        executor
      ) != 0) {
    pthread_cond_destroy(&executor->cond);
    pthread_mutex_destroy(&executor->mutex);
    free(executor);
    *rescode = -1;
    return NULL;
  }
  return executor;
}

MOONBIT_FFI_EXPORT
void
moondark_mysql_executor_release(moondark_mysql_executor_t *executor) {
  if (!executor) {
    return;
  }
  moondark_mysql_executor_lock(executor);
  executor->stopping = true;
  moondark_mysql_executor_wake(executor);
  moondark_mysql_executor_unlock(executor);
  pthread_join(executor->worker, NULL);
  pthread_cond_destroy(&executor->cond);
  pthread_mutex_destroy(&executor->mutex);
  free(executor);
}

bool
moondark_mysql_executor_submit(
  moondark_mysql_executor_t *executor,
  moondark_mysql_executor_job_t *job
) {
  moondark_mysql_executor_lock(executor);
  if (executor->stopping) {
    moondark_mysql_executor_unlock(executor);
    return false;
  }
  job->next = NULL;
  if (executor->tail) {
    executor->tail->next = job;
  } else {
    executor->head = job;
  }
  executor->tail = job;
  moondark_mysql_executor_wake(executor);
  moondark_mysql_executor_unlock(executor);
  return true;
}
