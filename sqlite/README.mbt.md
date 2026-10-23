# moondark_sqlite

SQLite integration module for MoonDark, providing a `database/sql` driver, `SqliteSessionStore`, `SqliteTaskBackend`, and `SqliteFileStore`.

## Quick Start

```mbt nocheck
///|
async test {
  @async.with_task_group(group => {
    let (db, executor) = @sqlite_database.open_db("app.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let rows = db.query("SELECT ? + 1 AS n", params=[41])
    defer rows.close()
  })
}
```

## Packages

| Package | Core Interface | Public API |
|---|---|---|
| `KKKIIO/moondark_sqlite/database` | `database/sql/driver` | `open_db`, `Driver` |
| `KKKIIO/moondark_sqlite/sessions` | `sessions.SessionStore` | `SqliteSessionStore` |
| `KKKIIO/moondark_sqlite/tasks` | `tasks.DBTaskBackend`, `tasks.TaskStore` | `SqliteTaskBackend` |
| `KKKIIO/moondark_sqlite/files` | `files.Catalog`, `files.FileStore` | `SqliteCatalog`, `SqliteFileStore` |

## Sessions

Apply [`sessions/schema.sql`](./sessions/schema.sql) to create the `sessions` table, then wire `SqliteSessionStore` into the session middleware:

```sql
CREATE TABLE IF NOT EXISTS sessions (
    session_key VARCHAR(64) PRIMARY KEY,
    session_data TEXT NOT NULL,
    expires_at BIGINT NOT NULL
);
```

```mbt nocheck
let store = @sqlite_sessions.SqliteSessionStore(db)
app.add_middleware(@sessions.middleware(store))
```
