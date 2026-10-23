-- Credentials table for PostgresCredentialStore
-- (KKKIIO/moondark_postgresql/auth). Apply it with psql or your
-- own migration tool, e.g. `psql "$DATABASE_URL" -f schema.sql`.
-- If you pass a different `table~` name to the store, rename the table
-- here too.
CREATE TABLE IF NOT EXISTS credentials (
    user_id VARCHAR(64) NOT NULL,
    kind VARCHAR(16) NOT NULL,
    provider VARCHAR(64) NOT NULL DEFAULT '',
    identifier VARCHAR(255) NOT NULL,
    secret TEXT NOT NULL,
    verified BOOLEAN NOT NULL DEFAULT FALSE,
    created_at BIGINT NOT NULL,
    last_used_at BIGINT,
    PRIMARY KEY (kind, provider, identifier)
);
CREATE INDEX IF NOT EXISTS credentials_user_id ON credentials (user_id);
