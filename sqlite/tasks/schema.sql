-- Task-result table for SqliteTaskBackend
-- (xziheng/moondark_sqlite/tasks). Apply it with the sqlite3 CLI,
-- `Conn::execute_script`, or your own migration tool, e.g.
-- `sqlite3 app.db < schema.sql`.
-- If you pass a different `table~` name to the backend, rename the
-- table and the index here too.

-- Per-connection: concurrent writers retry instead of failing with
-- SQLITE_BUSY. It only affects the connection that runs this script;
-- pool connections opened later need their own.
PRAGMA busy_timeout = 5000;

CREATE TABLE IF NOT EXISTS task_results (
    id TEXT PRIMARY KEY,
    task_name TEXT NOT NULL,
    status TEXT NOT NULL,
    args TEXT NOT NULL,
    run_after BIGINT,
    enqueued_at BIGINT NOT NULL,
    started_at BIGINT,
    finished_at BIGINT,
    attempts INTEGER NOT NULL,
    max_attempts INTEGER NOT NULL,
    return_value TEXT,
    errors TEXT NOT NULL,
    worker_ids TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS task_results_claim
    ON task_results (status, enqueued_at);
