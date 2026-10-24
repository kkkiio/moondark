///|
async test "sqlite session store passes the conformance suite" {
  @async.with_task_group(group => {
    let dir = @fs.tmpdir(prefix="moondark-sqlite-sessions")
    let (db, executor) = @sqlite_database.open_db("\{dir}/sessions.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    db.batch_execute(@fs.read_file("sessions/schema.sql").text())
    let store = @sessions.SqliteSessionStore(db)
    @sessionstest.check_session_store(store)
  })
}
