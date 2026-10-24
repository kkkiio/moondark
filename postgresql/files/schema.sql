-- File-object catalog for PostgresCatalog / new_file_store
-- (KKKIIO/moondark_postgresql/files). Apply it using psql,
-- DB::batch_execute, or your migration tool before constructing the store.
-- If you pass table~ to PostgresCatalog::new, rename this table accordingly.
-- Blob bytes live on disk under the CasFileStore root.

CREATE TABLE IF NOT EXISTS file_objects (
    key TEXT PRIMARY KEY,
    hash TEXT NOT NULL,
    size BIGINT NOT NULL CHECK (size >= 0),
    content_type TEXT
);
