-- Authoritative bootstrap snapshot: the union of every .sql
-- migration's end state (v0001_todos + v0002_moondark_sessions).
-- `todo load` installs this on a fresh database instead of replaying
-- the individual migrations; Run migrations (v0003_seed_todos) are
-- never covered. Keep it in sync when adding .sql versions.

CREATE TABLE todos (
    id INTEGER PRIMARY KEY,
    description TEXT NOT NULL,
    done INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS sessions (
    session_key VARCHAR(64) PRIMARY KEY,
    session_data TEXT NOT NULL,
    expires_at BIGINT NOT NULL
);
