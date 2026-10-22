-- File-object catalog table for SqliteCatalog / SqliteFileStore
-- (xziheng/moondark_sqlite/files). Apply it with the sqlite3 CLI,
-- `Conn::execute_script`, or your own migration tool, e.g.
-- `sqlite3 app.db < schema.sql`.
-- If you pass a different `table~` name to the catalog, rename the
-- table here too.

-- Per-connection: concurrent writers retry instead of failing with
-- SQLITE_BUSY. It only affects the connection that runs this script;
-- pool connections opened later need their own.
PRAGMA busy_timeout = 5000;

CREATE TABLE IF NOT EXISTS file_objects (
    key TEXT PRIMARY KEY,
    hash TEXT NOT NULL,
    size BIGINT NOT NULL,
    content_type TEXT NULL
);
