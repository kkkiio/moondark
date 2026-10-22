-- Session table for MysqlSessionStore
-- (xziheng/moondark_mysql/sessions). Apply it with the mysql CLI or
-- your own migration tool, e.g. `mysql app < schema.sql`.
-- If you pass a different `table~` name to the store, rename the table
-- here too.
CREATE TABLE IF NOT EXISTS sessions (
    session_key VARCHAR(64) PRIMARY KEY,
    session_data TEXT NOT NULL,
    expires_at BIGINT NOT NULL
);
