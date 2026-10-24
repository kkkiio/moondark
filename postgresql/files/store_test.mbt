///|
async test "PostgreSQL file store passes conformance and survives closing its pool" {
  let pg = @postgres.run()
  defer pg.cleanup()
  let root = @fs.tmpdir(prefix="moondark-postgres-files")
  let dsn = pg.connection_string(ssl_mode="disable")
  @async.with_task_group(group => {
    let (db, executor) = @postgresql_database.open_db(dsn)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    db.batch_execute(@fs.read_file("files/schema.sql").text())
    let store = @files.PostgresFileStore::new(
      db,
      root~,
      key="test-secret",
      url_prefix="/assets",
      default_expires=60_000,
      now=() => 1000L,
    )
    @filestest.check_file_store(store)
    store.put(
      key="persisted.pdf",
      b"%PDF-persisted",
      content_type="application/pdf",
    )
    store.put(key="copy.pdf", b"%PDF-persisted", content_type="application/pdf")
    let upload = store.presign_put(key="persisted.pdf")
    assert_eq(upload.expires_at, 61_000L)
    assert_true(upload.url.has_prefix("/assets/put/"))
    assert_true(
      store.presign_get(key="persisted.pdf").has_prefix("/assets/get/"),
    )
    db.close()
    let (second, executor2) = @postgresql_database.open_db(dsn)
    group.spawn_bg(no_wait=true, () => executor2.run())
    second.ready()
    defer second.close()
    let reopened = @files.PostgresFileStore::new(
      second,
      root~,
      key="test-secret",
    )
    assert_eq(reopened.get(key="persisted.pdf").binary(), b"%PDF-persisted")
    let catalog = @files.PostgresCatalog::new(second)
    let entry = catalog.lookup(key="persisted.pdf").unwrap()
    assert_eq(entry.size, 14L)
    assert_eq(entry.content_type, Some("application/pdf"))
    assert_eq(catalog.lookup(key="copy.pdf").unwrap().hash, entry.hash)
    reopened.put(key="persisted.pdf", "updated")
    assert_eq(reopened.get(key="persisted.pdf").text(), "updated")
    let updated = catalog.lookup(key="persisted.pdf").unwrap()
    assert_eq(updated.size, 7L)
    assert_eq(updated.content_type, None)
    assert_true(updated.hash != entry.hash)
    reopened.delete(key="persisted.pdf")
    assert_true(catalog.lookup(key="persisted.pdf") is None)
    assert_eq(reopened.get(key="copy.pdf").binary(), b"%PDF-persisted")
    reopened.delete(key="copy.pdf")
  })
}

///|
async test "PostgreSQL catalog supports custom tables, nullable metadata and atomic upserts" {
  let pg = @postgres.run()
  defer pg.cleanup()
  @async.with_task_group(group => {
    let (db, executor) = @postgresql_database.open_db(
      pg.connection_string(ssl_mode="disable"),
      max_open=2,
    )
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    db.batch_execute(
      @fs.read_file("files/schema.sql")
      .text()
      .replace_all(old="file_objects", new="custom_file_objects"),
    )
    let catalog = @files.PostgresCatalog::new(db, table="custom_file_objects")
    let key = "documents/报告's.pdf"
    assert_true(catalog.lookup(key~) is None)
    catalog.remove(key~)
    let entries : Array[@moondark_files.CatalogEntry] = [
      { hash: "first-hash", size: 14L, content_type: Some("application/pdf"), },
      { hash: "second-hash", size: 4_294_967_296L, content_type: None, },
    ]
    catalog.upsert(key~, entry=entries[0])
    assert_eq(
      catalog.lookup(key~).unwrap().content_type,
      Some("application/pdf"),
    )
    catalog.upsert(key~, entry=entries[1])
    let replaced = catalog.lookup(key~).unwrap()
    assert_eq(replaced.hash, "second-hash")
    assert_eq(replaced.size, 4_294_967_296L)
    assert_eq(replaced.content_type, None)
    ignore(
      @async.all(
        entries.map(entry => () => catalog.upsert(key~, entry~)),
        max_concurrent=2,
      ),
    )
    let stored = catalog.lookup(key~).unwrap()
    assert_true(
      entries.any(entry => {
        entry.hash == stored.hash &&
        entry.size == stored.size &&
        entry.content_type == stored.content_type
      }),
    )
    catalog.remove(key~)
    catalog.remove(key~)
    assert_true(catalog.lookup(key~) is None)
    assert_eq(db.stats().in_use, 0)
  })
}
