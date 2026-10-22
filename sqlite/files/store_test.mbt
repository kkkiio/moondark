///|
/// Open a `SqliteFileStore`-backed `CasFileStore` against a per-test
/// database file and run `f` with the pool executor running; the
/// package's `files/schema.sql` (which also sets `busy_timeout` on
/// that connection) has already run. Blobs are stored under `root`.
async fn with_store(
  path : String,
  root~ : String,
  key~ : String = "test-secret",
  f : async (@moondark_files.CasFileStore, @sql.DB) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let (db, executor) = @sqlite_database.open_db(path)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let conn = db.conn()
    defer conn.close()
    conn.execute_script(@fs.read_file("files/schema.sql").text())
    let store = @files.SqliteFileStore::new(db, root~, key~)
    ignore(db.execute("DELETE FROM file_objects"))
    f(store, db)
  })
}

///|
/// The regular files under `<root>/blobs`, i.e. the CAS blobs the
/// store has written so far, as full paths.
async fn blob_paths(root : String) -> Array[String] {
  let paths = []
  @fs.walk("\{root}/blobs", (dir, names) => {
    for name in names {
      let path = "\{dir}/\{name}"
      if @fs.kind(path) is @fs.FileKind::Regular {
        paths.push(path)
      }
    }
  })
  paths
}

///|
async test "sqlite file store passes the conformance suite" {
  let root = @fs.tmpdir(prefix="moondark-sqlite-files")
  with_store("_build/moondark-sqlite-files-conformance.db", root~, (store, _db) => {
    @filestest.check_file_store(store)
  })
}

///|
async test "catalog dedups blobs and delete unmaps the key" {
  let root = @fs.tmpdir(prefix="moondark-sqlite-files")
  with_store("_build/moondark-sqlite-files-cas.db", root~, (store, db) => {
    // the catalog row points at a hash-named blob on disk holding the
    // exact bytes that were put (the block scopes `rows`, so its read
    // cursor is closed before the writes below grab the write lock)
    store.put(key="a.txt", "same bytes", content_type="text/plain")
    let hash = {
      let rows = db.query("SELECT hash FROM file_objects WHERE key = ?", params=[
        "a.txt",
      ])
      defer rows.close()
      guard rows.next() is Some(row) else { fail("expected a catalog row") }
      guard row.get("hash") is Some(@driver.Value::String(hash)) else {
        fail("malformed hash column")
      }
      hash
    }
    let blobs = blob_paths(root)
    assert_eq(blobs.length(), 1)
    assert_true(blobs[0].has_suffix("/\{hash}"))
    assert_eq(@fs.read_file(blobs[0]).binary(), b"same bytes")
    // the same content under a second key shares the blob (dedup)
    store.put(key="b.txt", "same bytes")
    assert_eq(blob_paths(root).length(), 1)
    // overwriting retargets the key at a new blob; the old one stays
    // behind as an orphan — there is no GC yet
    store.put(key="a.txt", "v2")
    assert_eq(blob_paths(root).length(), 2)
    // delete drops only the catalog row; get raises NotFound while the
    // other key still resolves to the shared blob
    store.delete(key="a.txt")
    try {
      ignore(store.get(key="a.txt"))
      fail("get on a deleted key should raise NotFound")
    } catch {
      @moondark_files.NotFound(_) => ()
      e => raise e
    }
    assert_eq(store.get(key="b.txt").binary(), b"same bytes")
  })
}
