#include "mysql_glue.h"
#include <stdlib.h>
#include <string.h>

/* ---------- helpers ---------- */

/* Deep-copy a MoonBit bytes payload into a NUL-terminated malloc'd string.
 * An empty payload maps to NULL for optional connection parameters. */
static char *
moondark_mysql_dup_bytes(moonbit_bytes_t bytes, int empty_is_null) {
  int32_t length = Moonbit_array_length(bytes);
  if (empty_is_null && length == 0) {
    return NULL;
  }
  char *copy = malloc((size_t)length + 1);
  if (!copy) {
    return NULL;
  }
  if (length > 0) {
    memcpy(copy, bytes, (size_t)length);
  }
  copy[length] = '\0';
  return copy;
}

/* ---------- connect job ---------- */

typedef struct moondark_mysql_connect_job {
  moondark_mysql_job_t job;
  moondark_mysql_executor_t *executor;
  char *host;
  char *user;
  char *password;
  char *database;
  int32_t port;
  moondark_mysql_conn_t *conn;
} moondark_mysql_connect_job_t;

/* Closes a MYSQL handle on the executor's worker thread. Used when a
 * successful connect job is released without its conn being taken. */
typedef struct moondark_mysql_drain_job {
  moondark_mysql_executor_job_t executor_job;
  MYSQL *mysql;
  void *wrapper;
} moondark_mysql_drain_job_t;

static void
moondark_mysql_run_drain_job(moondark_mysql_executor_job_t *executor_job) {
  moondark_mysql_drain_job_t *drain =
    (moondark_mysql_drain_job_t *)executor_job;
  if (drain->mysql) {
    mysql_close(drain->mysql);
  }
  free(drain->wrapper);
  free(drain);
}

static void
moondark_mysql_drain_conn(moondark_mysql_conn_t *conn) {
  if (!conn) {
    return;
  }
  moondark_mysql_drain_job_t *drain = calloc(1, sizeof(*drain));
  if (drain && conn->executor) {
    drain->mysql = conn->mysql;
    drain->wrapper = conn;
    drain->executor_job.next = NULL;
    drain->executor_job.run = moondark_mysql_run_drain_job;
    if (moondark_mysql_executor_submit(
          conn->executor,
          &drain->executor_job
        )) {
      return;
    }
  }
  /* The executor is gone or stopping: the handle leaks rather than being
   * touched off the worker thread. */
  free(drain);
  free(conn);
}

static void
moondark_mysql_connect_job_free_strings(moondark_mysql_connect_job_t *job) {
  free(job->host);
  free(job->user);
  free(job->password);
  free(job->database);
  job->host = NULL;
  job->user = NULL;
  job->password = NULL;
  job->database = NULL;
}

static void
moondark_mysql_run_connect_job(moondark_mysql_executor_job_t *executor_job) {
  moondark_mysql_connect_job_t *connect_job =
    (moondark_mysql_connect_job_t *)executor_job;
  moondark_mysql_job_t *job = &connect_job->job;
  MYSQL *mysql = mysql_init(NULL);
  if (!mysql) {
    moondark_mysql_job_capture_oom(job);
  } else {
    my_bool reconnect_off = 0;
    mysql_options(mysql, MYSQL_OPT_RECONNECT, &reconnect_off);
    /* Force TCP: libmysqlclient maps the literal host "localhost" to the
     * Unix socket, but this driver only speaks TCP — DSNs carry no
     * socket-path option. */
    unsigned int protocol = MYSQL_PROTOCOL_TCP;
    mysql_options(mysql, MYSQL_OPT_PROTOCOL, &protocol);
    /* Opportunistic TLS: encrypt when the server offers it, but never verify
     * the server certificate — the DSN surface has no CA parameters, and
     * requiring them would break plain servers and self-signed deployments
     * (e.g. test containers) alike. */
    my_bool verify_off = 0;
    mysql_options(
      mysql,
      MYSQL_OPT_SSL_VERIFY_SERVER_CERT,
      &verify_off
    );
    if (mysql_real_connect(
          mysql,
          connect_job->host,
          connect_job->user,
          connect_job->password,
          connect_job->database,
          (unsigned int)connect_job->port,
          NULL,
          CLIENT_MULTI_STATEMENTS
        )) {
      moondark_mysql_conn_t *conn = calloc(1, sizeof(*conn));
      if (conn) {
        conn->mysql = mysql;
        conn->executor = connect_job->executor;
        connect_job->conn = conn;
      } else {
        moondark_mysql_job_capture_oom(job);
        mysql_close(mysql);
      }
    } else {
      moondark_mysql_job_capture_error(job, mysql);
      mysql_close(mysql);
    }
  }
  moondark_mysql_connect_job_free_strings(connect_job);
  moondark_mysql_job_publish_result(job);
}

static void
moondark_mysql_connect_job_destroy(moondark_mysql_job_t *job) {
  moondark_mysql_connect_job_t *connect_job =
    (moondark_mysql_connect_job_t *)job;
  moondark_mysql_connect_job_free_strings(connect_job);
  if (connect_job->conn) {
    /* Success but the wrapper was never taken: close it on the worker. */
    moondark_mysql_drain_conn(connect_job->conn);
    connect_job->conn = NULL;
  }
}

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
) {
  *rescode = 0;
  if (!executor) {
    *rescode = -1;
    return NULL;
  }
  moondark_mysql_connect_job_t *connect_job =
    calloc(1, sizeof(*connect_job));
  if (!connect_job) {
    *rescode = -1;
    return NULL;
  }
  connect_job->job.kind = MOONDARK_MYSQL_JOB_CONNECT;
  connect_job->job.destroy = moondark_mysql_connect_job_destroy;
  connect_job->executor = executor;
  connect_job->port = port;
  connect_job->host = moondark_mysql_dup_bytes(host, 0);
  connect_job->user = moondark_mysql_dup_bytes(user, 1);
  connect_job->password = moondark_mysql_dup_bytes(password, 1);
  connect_job->database = moondark_mysql_dup_bytes(database, 1);
  if (!connect_job->host ||
      (Moonbit_array_length(user) > 0 && !connect_job->user) ||
      (Moonbit_array_length(password) > 0 && !connect_job->password) ||
      (Moonbit_array_length(database) > 0 && !connect_job->database)) {
    moondark_mysql_connect_job_free_strings(connect_job);
    free(connect_job);
    *rescode = -1;
    return NULL;
  }
  if (!moondark_mysql_job_submit(
        &connect_job->job,
        executor,
        notification,
        moondark_mysql_run_connect_job,
        rescode
      )) {
    moondark_mysql_connect_job_free_strings(connect_job);
    free(connect_job);
    return NULL;
  }
  return &connect_job->job;
}

MOONBIT_FFI_EXPORT
moondark_mysql_conn_t *
moondark_mysql_job_take_conn(moondark_mysql_job_t *job) {
  if (!job ||
      job->kind != MOONDARK_MYSQL_JOB_CONNECT ||
      !moondark_mysql_job_result_is_published(job) ||
      job->err_no != 0) {
    return NULL;
  }
  moondark_mysql_connect_job_t *connect_job =
    (moondark_mysql_connect_job_t *)job;
  moondark_mysql_conn_t *conn = connect_job->conn;
  connect_job->conn = NULL;
  return conn;
}

/* ---------- query job (drains every result of a multi-statement script) ---- */

typedef struct moondark_mysql_query_job {
  moondark_mysql_job_t job;
  moondark_mysql_conn_t *conn;
  char *sql;
  unsigned long sql_length;
} moondark_mysql_query_job_t;

static void
moondark_mysql_run_query_job(moondark_mysql_executor_job_t *executor_job) {
  moondark_mysql_query_job_t *query_job =
    (moondark_mysql_query_job_t *)executor_job;
  moondark_mysql_job_t *job = &query_job->job;
  MYSQL *mysql = query_job->conn->mysql;
  if (mysql_real_query(mysql, query_job->sql, query_job->sql_length)) {
    moondark_mysql_job_capture_error(job, mysql);
  } else {
    for (;;) {
      MYSQL_RES *result = mysql_store_result(mysql);
      if (result) {
        mysql_free_result(result);
      } else if (mysql_field_count(mysql) != 0) {
        /* A result set was expected but could not be stored. */
        moondark_mysql_job_capture_error(job, mysql);
        break;
      }
      job->affected_rows = (int64_t)mysql_affected_rows(mysql);
      job->insert_id = (int64_t)mysql_insert_id(mysql);
      int next = mysql_next_result(mysql);
      if (next < 0) {
        break; /* no more results */
      }
      if (next > 0) {
        moondark_mysql_job_capture_error(job, mysql);
        break;
      }
    }
  }
  free(query_job->sql);
  query_job->sql = NULL;
  moondark_mysql_job_publish_result(job);
}

static void
moondark_mysql_query_job_destroy(moondark_mysql_job_t *job) {
  moondark_mysql_query_job_t *query_job =
    (moondark_mysql_query_job_t *)job;
  free(query_job->sql);
  query_job->sql = NULL;
}

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_query_job(
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
  moondark_mysql_query_job_t *query_job = calloc(1, sizeof(*query_job));
  if (!query_job) {
    *rescode = -1;
    return NULL;
  }
  int32_t sql_length = Moonbit_array_length(sql);
  query_job->sql = malloc((size_t)sql_length + 1);
  if (!query_job->sql) {
    free(query_job);
    *rescode = -1;
    return NULL;
  }
  memcpy(query_job->sql, sql, (size_t)sql_length);
  query_job->sql[sql_length] = '\0';
  query_job->sql_length = (unsigned long)sql_length;
  query_job->conn = conn;
  query_job->job.kind = MOONDARK_MYSQL_JOB_QUERY;
  query_job->job.destroy = moondark_mysql_query_job_destroy;
  if (!moondark_mysql_job_submit(
        &query_job->job,
        executor,
        notification,
        moondark_mysql_run_query_job,
        rescode
      )) {
    free(query_job->sql);
    free(query_job);
    return NULL;
  }
  return &query_job->job;
}

/* ---------- ping / reset / conn_close jobs ---------- */

typedef struct moondark_mysql_conn_job {
  moondark_mysql_job_t job;
  moondark_mysql_conn_t *conn;
} moondark_mysql_conn_job_t;

static void
moondark_mysql_run_ping_job(moondark_mysql_executor_job_t *executor_job) {
  moondark_mysql_conn_job_t *conn_job =
    (moondark_mysql_conn_job_t *)executor_job;
  moondark_mysql_job_t *job = &conn_job->job;
  MYSQL *mysql = conn_job->conn->mysql;
  if (mysql_ping(mysql)) {
    moondark_mysql_job_capture_error(job, mysql);
  }
  moondark_mysql_job_publish_result(job);
}

static void
moondark_mysql_run_reset_job(moondark_mysql_executor_job_t *executor_job) {
  moondark_mysql_conn_job_t *conn_job =
    (moondark_mysql_conn_job_t *)executor_job;
  moondark_mysql_job_t *job = &conn_job->job;
  MYSQL *mysql = conn_job->conn->mysql;
  /* Roll back a transaction left open on a pooled connection. Deliberately
   * NOT mysql_reset_connection: that call releases server-side prepared
   * statements, which would invalidate the pool's per-connection
   * statement cache. ROLLBACK is a no-op outside a transaction. */
  if (mysql_rollback(mysql)) {
    moondark_mysql_job_capture_error(job, mysql);
  }
  moondark_mysql_job_publish_result(job);
}

static void
moondark_mysql_run_conn_close_job(
  moondark_mysql_executor_job_t *executor_job
) {
  moondark_mysql_conn_job_t *conn_job =
    (moondark_mysql_conn_job_t *)executor_job;
  moondark_mysql_job_t *job = &conn_job->job;
  mysql_close(conn_job->conn->mysql);
  conn_job->conn->mysql = NULL;
  free(conn_job->conn);
  conn_job->conn = NULL;
  moondark_mysql_job_publish_result(job);
}

static moondark_mysql_job_t *
moondark_mysql_conn_job_submit(
  moondark_mysql_executor_t *executor,
  moondark_mysql_conn_t *conn,
  int notification,
  int32_t *rescode,
  int32_t kind,
  void (*run)(moondark_mysql_executor_job_t *job)
) {
  *rescode = 0;
  if (!executor || !conn || !conn->mysql) {
    *rescode = -1;
    return NULL;
  }
  moondark_mysql_conn_job_t *conn_job = calloc(1, sizeof(*conn_job));
  if (!conn_job) {
    *rescode = -1;
    return NULL;
  }
  conn_job->conn = conn;
  conn_job->job.kind = kind;
  if (!moondark_mysql_job_submit(
        &conn_job->job,
        executor,
        notification,
        run,
        rescode
      )) {
    free(conn_job);
    return NULL;
  }
  return &conn_job->job;
}

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_ping_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_conn_t *conn,
  int notification,
  int32_t *rescode
) {
  return moondark_mysql_conn_job_submit(
    executor,
    conn,
    notification,
    rescode,
    MOONDARK_MYSQL_JOB_PING,
    moondark_mysql_run_ping_job
  );
}

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_reset_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_conn_t *conn,
  int notification,
  int32_t *rescode
) {
  return moondark_mysql_conn_job_submit(
    executor,
    conn,
    notification,
    rescode,
    MOONDARK_MYSQL_JOB_RESET,
    moondark_mysql_run_reset_job
  );
}

MOONBIT_FFI_EXPORT
moondark_mysql_job_t *
moondark_mysql_conn_close_job(
  moondark_mysql_executor_t *executor,
  moondark_mysql_conn_t *conn,
  int notification,
  int32_t *rescode
) {
  return moondark_mysql_conn_job_submit(
    executor,
    conn,
    notification,
    rescode,
    MOONDARK_MYSQL_JOB_CONN_CLOSE,
    moondark_mysql_run_conn_close_job
  );
}
