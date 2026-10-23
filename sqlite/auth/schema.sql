-- Credentials table for SqliteCredentialStore
-- (KKKIIO/moondark_sqlite/auth). Apply it with the sqlite3 CLI,
-- `Conn::execute_script`, or your own migration tool, e.g.
-- `sqlite3 app.db < schema.sql`.
-- If you pass a different `table~` name to the store, rename the table
-- here too.
CREATE TABLE IF NOT EXISTS credentials (
    user_id VARCHAR(64) NOT NULL,
    kind VARCHAR(16) NOT NULL,
    provider VARCHAR(64) NOT NULL DEFAULT '',
    identifier VARCHAR(255) NOT NULL,
    secret TEXT NOT NULL,
    verified INTEGER NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    last_used_at BIGINT,
    PRIMARY KEY (kind, provider, identifier)
);
CREATE INDEX IF NOT EXISTS credentials_user_id ON credentials (user_id);
