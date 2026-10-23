-- Task-result table for PostgresTaskBackend
-- (KKKIIO/moondark_postgresql/tasks). Apply it with psql or your own
-- migration tool, e.g. `psql "$DATABASE_URL" -f schema.sql`.
-- If you pass a different `table~` name to the backend, rename the
-- table and the index here too.
CREATE TABLE IF NOT EXISTS task_results (
    id TEXT PRIMARY KEY,
    task_name TEXT NOT NULL,
    status TEXT NOT NULL,
    args JSONB NOT NULL,
    run_after BIGINT NULL,
    enqueued_at BIGINT NOT NULL,
    started_at BIGINT NULL,
    finished_at BIGINT NULL,
    attempts INTEGER NOT NULL,
    max_attempts INTEGER NOT NULL,
    return_value JSONB NULL,
    errors JSONB NOT NULL,
    worker_ids JSONB NOT NULL
);

-- Covers exactly the rows `claim` scans: runnable `ready` rows plus
-- reclaimable `running` ones.
CREATE INDEX IF NOT EXISTS task_results_claim_idx
    ON task_results (enqueued_at)
    WHERE status IN ('ready', 'running');
