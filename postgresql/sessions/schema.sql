-- Session table for PostgresSessionStore
-- (KKKIIO/moondark_postgresql/sessions). Apply it with psql or your
-- own migration tool, e.g. `psql "$DATABASE_URL" -f schema.sql`.
-- If you pass a different `table~` name to the store, rename the table
-- here too.
CREATE TABLE IF NOT EXISTS sessions (
    session_key VARCHAR(64) PRIMARY KEY,
    session_data TEXT NOT NULL,
    expires_at BIGINT NOT NULL
);
