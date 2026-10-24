///|
async test "postgres file store passes conformance and persists its catalog across pools" {
  let pg = @postgres.run()
  defer pg.cleanup()
  let root = @fs.tmpdir(prefix="moondark-postgres-files")
  @async.with_task_group(group => {
    let (db, executor) = @postgresql_database.open_db(
      pg.connection_string(ssl_mode="disable"),
    )
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    {
      let conn = db.conn()
      defer conn.close()
      conn.execute_script(@fs.read_file("files/schema.sql").text())
    }
    let store = @files.PostgresFileStore::new(db, root~, key="test-secret")
    @filestest.check_file_store(store)
    store.put(
      key="persisted.pdf",
      b"%PDF-persisted",
      content_type="application/pdf",
    )
    let (second, executor2) = @postgresql_database.open_db(
      pg.connection_string(ssl_mode="disable"),
    )
    group.spawn_bg(no_wait=true, () => executor2.run())
    second.ready()
    defer second.close()
    let reopened = @files.PostgresFileStore::new(
      second,
      root~,
      key="test-secret",
    )
    assert_eq(reopened.get(key="persisted.pdf").binary(), b"%PDF-persisted")
    let entry = @files.PostgresCatalog::new(second)
      .lookup(key="persisted.pdf")
      .unwrap()
    assert_eq(entry.size, 14L)
    assert_eq(entry.content_type, Some("application/pdf"))
    reopened.put(key="persisted.pdf", "updated")
    assert_eq(store.get(key="persisted.pdf").text(), "updated")
    assert_eq(
      @files.PostgresCatalog::new(db).lookup(key="persisted.pdf").unwrap().content_type,
      None,
    )
  })
}
