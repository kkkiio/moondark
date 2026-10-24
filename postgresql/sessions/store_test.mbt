///|
async test "postgres session store passes the conformance suite" {
  let pg = @postgres.run()
  defer pg.cleanup()
  @async.with_task_group(group => {
    let (db, executor) = @postgresql_database.open_db(
      pg.connection_string(ssl_mode="disable"),
    )
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    db.batch_execute(@fs.read_file("sessions/schema.sql").text())
    let store = @sessions.PostgresSessionStore(db)
    @sessionstest.check_session_store(store)
  })
}
