///|
/// Bookkeeping I/O for `moondark_migrations` (the applied set) and
/// `moondark_migration_records` (the attempt log). Queries run through
/// the normal prepared-statement path with each dialect's native
/// placeholders (`$N` for Postgres, `?` otherwise); table names are
/// interpolated but validated to identifier shape by `Migrator::new`.

///|
/// The applied set: `name -> (checksum, applied_at)`.
async fn Migrator::applied_set(self : Migrator) -> Map[String, (String, Int64)] {
  let rows = self.conn.query_all(
    "SELECT name, checksum, applied_at FROM \{self.migrations_table}",
  )
  let out : Map[String, (String, Int64)] = Map([])
  for row in rows {
    out[(row.get_name("name") : String)] = (
      (row.get_name("checksum") : String),
      (row.get_name("applied_at") : Int64),
    )
  }

  out
}

///|
/// Names of migrations whose newest attempt never finished — either a
/// crash mid-migration or a concurrent run.
async fn Migrator::unfinished(self : Migrator) -> Array[String] {
  let rows = self.conn.query_all(
    "SELECT DISTINCT name FROM \{self.records_table} WHERE status = 'started'",
  )
  let out : Array[String] = []
  for row in rows {
    out.push((row.get_name("name") : String))
  }

  out
}

///|
/// Latest attempt status per migration name.
async fn Migrator::last_status(self : Migrator) -> Map[String, String] {
  let rows = self.conn.query_all(
    "SELECT name, status FROM \{self.records_table} ORDER BY id",
  )
  let out : Map[String, String] = Map([])
  for row in rows {
    out[(row.get_name("name") : String)] = (row.get_name("status") : String)
  }

  out
}

///|
/// Open an attempt record (`status = 'started'`) and return its row
/// id. Postgres takes the `RETURNING` path; `last_insert_id` covers
/// SQLite and MySQL.
async fn Migrator::insert_started(self : Migrator, name : String) -> Int64 {
  if self.dialect is Postgres {
    let rows = self.conn.query_opt(
      "INSERT INTO \{self.records_table} (name, status, started_at) VALUES ($1, 'started', $2) RETURNING id",
      params=[name, now_ms()],
    )
    let id = match rows {
      Some(row) => (row.get_name("id") : Int64)
      None => -1
    }

    id
  } else {
    let result = self.conn.execute(
      "INSERT INTO \{self.records_table} (name, status, started_at) VALUES (?, 'started', ?)",
      params=[name, now_ms()],
    )
    result.last_insert_id.unwrap_or(-1)
  }
}

///|
/// Close an attempt record with its terminal status and wall time.
async fn Migrator::finish_record(
  self : Migrator,
  id : Int64,
  status : String,
  error : String,
  started_ms : Int64,
) -> Unit {
  if id < 0 {
    return
  }
  let sql = match self.dialect {
    Postgres =>
      "UPDATE \{self.records_table} SET status = $1, error = $2, finished_at = $3, duration_ms = $4 WHERE id = $5"
    Sqlite | Mysql =>
      "UPDATE \{self.records_table} SET status = ?, error = ?, finished_at = ?, duration_ms = ? WHERE id = ?"
  }
  ignore(
    self.conn.execute(sql, params=[
      status,
      error,
      now_ms(),
      now_ms() - started_ms,
      id,
    ]),
  )
}

///|
/// Record `name` in the applied set. Runs inside the migration's own
/// transaction so it commits or rolls back with the DDL.
async fn Migrator::insert_applied(
  self : Migrator,
  name : String,
  checksum : String,
  applied_at : Int64,
) -> Unit {
  let sql = match self.dialect {
    Postgres =>
      "INSERT INTO \{self.migrations_table} (name, checksum, applied_at) VALUES ($1, $2, $3)"
    Sqlite | Mysql =>
      "INSERT INTO \{self.migrations_table} (name, checksum, applied_at) VALUES (?, ?, ?)"
  }
  ignore(self.conn.execute(sql, params=[name, checksum, applied_at]))
}
