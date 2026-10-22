///|
async test "sqlite session store passes the conformance suite" {
  @async.with_task_group(group => {
    let (db, executor) = @sqlite_database.open_db(
      "_build/moondark-sqlite-sessions-test.db",
    )
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let conn = db.conn()
    defer conn.close()
    conn.execute_script(@fs.read_file("sessions/schema.sql").text())
    let store = @sessions.SqliteSessionStore(db)
    @sessionstest.check_session_store(store)
  })
}
