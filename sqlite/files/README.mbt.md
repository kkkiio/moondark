# moondark_sqlite/files

SQLite catalog for `xziheng/moondark/files`: `SqliteCatalog` stores the key → blob index in a SQLite table while `SqliteFileStore` builds a `CasFileStore` that keeps the content-addressed blobs on disk.

## Quick Start

Apply [`schema.sql`](./schema.sql) to create the `file_objects` table, then build the store and use its `FileStore` methods and `routes()` directly:

```mbt check
///|
async test {
  @async.with_task_group(group => {
    let (db, executor) = @sqlite_database.open_db(
      "_build/moondark-sqlite-files-readme.db",
    )
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let conn = db.conn()
    defer conn.close()
    conn.execute_script(@fs.read_file("files/schema.sql").text())
    let store = @files.SqliteFileStore::new(
      db,
      root="/tmp/moondark-files-demo",
      key="app-secret",
    )
    store.put(key="docs/hello.txt", "hello moondark")
    assert_eq(store.get(key="docs/hello.txt").binary(), b"hello moondark")
    let url = store.presign_get(key="docs/hello.txt")
    assert_true(!url.is_empty())
  })
}
```

`schema.sql` also sets `PRAGMA busy_timeout` on the connection that runs it — pool connections opened later need their own (see the comments in the file). Mount `store.routes()` on your moonback `App` to serve the presigned upload/download URLs.
