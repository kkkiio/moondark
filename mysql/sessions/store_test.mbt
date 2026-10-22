///|
/// Run the package's `sessions/schema.sql` through `execute_script`:
/// the driver negotiates `CLIENT_MULTI_STATEMENTS`, so the whole file
/// (comments included) runs as one script.
async fn apply_schema(db : @sql.DB) -> Unit {
  let conn = db.conn()
  defer conn.close()
  conn.execute_script(@fs.read_file("sessions/schema.sql").text())
}

///|
async test "mysql session store passes the conformance suite" {
  @async.with_task_group(group => {
    let container = @mysql.run()
    defer container.cleanup()
    let (db, executor) = @mysql_database.open_db(container.dsn())
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    apply_schema(db)
    let store = @sessions.MysqlSessionStore(db)
    @sessionstest.check_session_store(store)
  })
}
