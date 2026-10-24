CREATE TABLE IF NOT EXISTS file_objects (
    key TEXT PRIMARY KEY,
    hash TEXT NOT NULL,
    size BIGINT NOT NULL CHECK (size >= 0),
    content_type TEXT
);
