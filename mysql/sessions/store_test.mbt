///|
/// Run the package's `sessions/schema.sql`: moonmysql cannot execute
/// multi-statement scripts, so `--` comment lines are stripped and the
/// statements are run one by one.
async fn apply_schema(db : @sql.DB) -> Unit {
  let lines : Array[String] = []
  for line in @fs.read_file("sessions/schema.sql").text().split("\n") {
    let line = line.trim().to_owned()
    if line.length() > 0 && !line.has_prefix("--") {
      lines.push(line)
    }
  }
  for stmt in lines.join("\n").split(";") {
    let stmt = stmt.trim().to_owned()
    if stmt.length() > 0 {
      ignore(db.execute(stmt))
    }
  }
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
