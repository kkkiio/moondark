///|
async test "mysql session store passes the conformance suite" {
  @async.with_task_group(group => {
    let container = @mysql.run()
    defer container.cleanup()
    let (db, executor) = @mysql_database.open_db(container.dsn())
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let store = @sessions.MysqlSessionStore(db)
    store.migrate()
    @sessionstest.check_session_store(store)
  })
}
