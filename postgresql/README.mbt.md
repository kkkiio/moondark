# moondark_postgresql

PostgreSQL integration module for MoonDark, providing a `database/sql` driver, `PostgresSessionStore`, `PostgresTaskBackend`, `PostgresCredentialStore`, and `PostgresFileStore`.

## Quick Start

```mbt nocheck
///|
async test {
  @async.with_task_group(group => {
    let (db, executor) = @postgresql_database.open_db(
      "postgres://user:pass@localhost:5432/app?sslmode=disable",
    )
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let rows = db.query("SELECT $1::int4 + 1 AS n", params=[41])
    defer rows.close()
  })
}
```

## Packages

| Package | Core Interface | Public API |
|---|---|---|
| `KKKIIO/moondark_postgresql/database` | `database/sql/driver` | `open_db`, `Driver` |
| `KKKIIO/moondark_postgresql/sessions` | `sessions.SessionStore` | `PostgresSessionStore` |
| `KKKIIO/moondark_postgresql/tasks` | `tasks.DBTaskBackend`, `tasks.TaskStore` | `PostgresTaskBackend` |
| `KKKIIO/moondark_postgresql/files` | `files.Catalog`, `files.FileStore` | `PostgresCatalog`, `PostgresFileStore` |
| `KKKIIO/moondark_postgresql/auth` | `auth.CredentialStore` | `PostgresCredentialStore` |

## Sessions

Apply [`sessions/schema.sql`](./sessions/schema.sql) to create the `sessions` table, then wire `PostgresSessionStore` into the session middleware:

```sql
CREATE TABLE IF NOT EXISTS sessions (
    session_key VARCHAR(64) PRIMARY KEY,
    session_data TEXT NOT NULL,
    expires_at BIGINT NOT NULL
);
```

```mbt nocheck
let store = @postgresql_sessions.PostgresSessionStore(db)
app.add_middleware(@sessions.middleware(store))
```

## Files

Apply [`files/schema.sql`](./files/schema.sql), then create a persistent file
store. PostgreSQL holds the catalog; immutable blobs live under `root`:

```mbt nocheck
let files = @postgresql_files.PostgresFileStore::new(
  db, root="./uploads", key="app-secret",
)
files.put(key="documents/paper.pdf", pdf, content_type="application/pdf")
```
