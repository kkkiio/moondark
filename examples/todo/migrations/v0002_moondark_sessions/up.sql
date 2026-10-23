-- Session table for SqliteSessionStore
-- (KKKIIO/moondark_sqlite/sessions). Apply it with the sqlite3 CLI,
-- `Conn::execute_script`, or your own migration tool, e.g.
-- `sqlite3 app.db < schema.sql`.
-- If you pass a different `table~` name to the store, rename the table
-- here too.
CREATE TABLE IF NOT EXISTS sessions (
    session_key VARCHAR(64) PRIMARY KEY,
    session_data TEXT NOT NULL,
    expires_at BIGINT NOT NULL
);
