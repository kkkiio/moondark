///|
async test "sqlite credential store passes the conformance suite" {
  @async.with_task_group(group => {
    // `:memory:` is per-connection; cap the pool at one connection so
    // every query sees the same database.
    let (db, executor) = @sqlite_database.open_db(":memory:", max_open=1)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let conn = db.conn()
    conn.execute_script(@fs.read_file("auth/schema.sql").text())
    conn.close()
    let store = @auth.SqliteCredentialStore(db)
    @authtest.check_credential_store(store)
  })
}
