# moondark_postgresql/files

PostgreSQL catalog for MoonDark file storage: `PostgresCatalog` persists file metadata while `new_file_store` builds a content-addressed `CasFileStore` with blobs on disk.

## Quick Start

Apply [`schema.sql`](./schema.sql) to create the `file_objects` table, then construct the store:

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
    db.batch_execute(@fs.read_file("files/schema.sql").text())
    let store = @files.new_file_store(db, root="./uploads", key="app-secret")
    store.put(key="docs/hello.txt", "hello moondark", content_type="text/plain")
    assert_eq(store.get(key="docs/hello.txt").binary(), b"hello moondark")
    let url = store.presign_get(key="docs/hello.txt")
    assert_true(!url.is_empty())
  })
}
```

Import `KKKIIO/moondark_postgresql/files` as `@files` and mount `store.routes()` on your MoonBack app to serve presigned upload and download URLs. The `root` directory is created automatically. Store instances sharing the same catalog must also share this blob directory.

## Catalog

`PostgresCatalog::new(db, table="file_objects")` implements `KKKIIO/moondark/files.Catalog` with PostgreSQL's atomic `INSERT ... ON CONFLICT ... DO UPDATE`. Replacing a key updates its hash, size, and optional content type together. Deleting a key removes its catalog entry; immutable blobs remain on disk for future garbage collection.

For a custom table, apply the same schema under that name and pass the catalog to `CasFileStore::new(root~, catalog~, key~)`. Table names must be trusted SQL identifiers. Query values use native `$N` parameters and typed decoding through `KKKIIO/moondark/database`.
