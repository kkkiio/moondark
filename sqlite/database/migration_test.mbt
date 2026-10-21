///|
fn open(file : String) -> (@sql.DB, @sql.DBExecutor) raise {
  @database.open_db("_build/\{file}")
}

///|
fn two_migrations() -> Array[@migration.Migration] {
  [
    @migration.Migration::sql(
      name="0001_items",
      sql="CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO items VALUES (1, 'a;b');",
    ),
    @migration.Migration::sql(
      name="0002_price",
      sql="ALTER TABLE items ADD COLUMN price REAL DEFAULT 0;",
    ),
  ]
}

///|
async fn count_rows(db : @sql.DB, sql : String) -> Int64 {
  let rows = db.query(sql)
  defer rows.close()
  let mut n = 0L
  while rows.next() is Some(_) {
    n += 1
  }
  n
}

///|
async test "migrator up applies pending and is idempotent" {
  @async.with_task_group(group => {
    let (db, executor) = open("moondark-mig-up.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    ignore(db.execute("DROP TABLE IF EXISTS moondark_migrations"))
    ignore(db.execute("DROP TABLE IF EXISTS moondark_migration_records"))
    ignore(db.execute("DROP TABLE IF EXISTS items"))
    let migrator = @migration.Migrator::new(
      conn=db.conn(),
      dialect=@migration.Dialect::Sqlite,
    )
    let applied = migrator.up(two_migrations()[:])
    assert_eq(applied, ["0001_items", "0002_price"])
    assert_eq(migrator.up(two_migrations()[:]), [])
    let rows = db.query("SELECT name, price FROM items")
    defer rows.close()
    guard rows.next() is Some(row) else { fail("expected row") }
    assert_true(row.get("name") is Some(String("a;b")))
    assert_true(row.get("price") is Some(Double(0.0)))
    for s in migrator.status(two_migrations()[:]) {
      assert_true(s.applied)
    }
    assert_eq(count_rows(db, "SELECT id FROM moondark_migration_records"), 2)
  })
}

///|
async test "failed migration rolls back and records failure" {
  @async.with_task_group(group => {
    let (db, executor) = open("moondark-mig-fail.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    ignore(db.execute("DROP TABLE IF EXISTS moondark_migrations"))
    ignore(db.execute("DROP TABLE IF EXISTS moondark_migration_records"))
    ignore(db.execute("DROP TABLE IF EXISTS gone"))
    let migrator = @migration.Migrator::new(
      conn=db.conn(),
      dialect=@migration.Dialect::Sqlite,
    )
    let bad = [
      @migration.Migration::sql(
        name="0001_bad",
        sql="CREATE TABLE gone(id INTEGER); INSERT INTO nonexistent VALUES (1);",
      ),
    ]
    try {
      ignore(migrator.up(bad[:]))
      fail("expected ApplyFailed")
    } catch {
      e =>
        if e is @migration.ApplyFailed(_, name~) {
          assert_eq(name, "0001_bad")
        } else {
          raise e
        }
    }
    // DDL was inside the transaction: table must be gone.
    assert_eq(
      count_rows(db, "SELECT name FROM sqlite_master WHERE name='gone'"),
      0,
    )
    // The applied set is empty and the failure is in the records table.
    assert_eq(count_rows(db, "SELECT name FROM moondark_migrations"), 0)
    let rows = db.query(
      "SELECT status, error FROM moondark_migration_records ORDER BY id",
    )
    defer rows.close()
    let statuses : Array[String] = []
    while rows.next() is Some(row) {
      guard row.get("status") is Some(String(s)) else { fail("bad record") }
      statuses.push(s)
      guard row.get("error") is Some(String(err)) && err.length() > 0 else {
        fail("expected error detail")
      }
    }
    // one record per attempt: the `started` row is updated in place.
    assert_eq(statuses, ["failed"])
  })
}

///|
async test "dirty record blocks further migration" {
  @async.with_task_group(group => {
    let (db, executor) = open("moondark-mig-dirty.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    ignore(db.execute("DROP TABLE IF EXISTS moondark_migrations"))
    ignore(db.execute("DROP TABLE IF EXISTS moondark_migration_records"))
    let migrator = @migration.Migrator::new(
      conn=db.conn(),
      dialect=@migration.Dialect::Sqlite,
    )
    migrator.ensure_tables()
    ignore(
      db.execute(
        "INSERT INTO moondark_migration_records(name, status, started_at) VALUES ('9999_stale', 'started', 0)",
      ),
    )
    try {
      ignore(migrator.up(two_migrations()[:]))
      fail("expected DirtyState")
    } catch {
      e =>
        if e is @migration.DirtyState(names) {
          assert_eq(names, ["9999_stale"])
        } else {
          raise e
        }
    }
  })
}

///|
async test "checksum mismatch detects edited migration" {
  @async.with_task_group(group => {
    let (db, executor) = open("moondark-mig-checksum.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    ignore(db.execute("DROP TABLE IF EXISTS moondark_migrations"))
    ignore(db.execute("DROP TABLE IF EXISTS moondark_migration_records"))
    ignore(db.execute("DROP TABLE IF EXISTS a"))
    let migrator = @migration.Migrator::new(
      conn=db.conn(),
      dialect=@migration.Dialect::Sqlite,
    )
    let v1 = [
      @migration.Migration::sql(name="0001_a", sql="CREATE TABLE a(x INTEGER);"),
    ]
    ignore(migrator.up(v1[:]))
    let v2 = [
      @migration.Migration::sql(
        name="0001_a",
        sql="CREATE TABLE a(x INTEGER, y INTEGER);",
      ),
    ]
    try {
      ignore(migrator.up(v2[:]))
      fail("expected ChecksumMismatch")
    } catch {
      e =>
        if e is @migration.ChecksumMismatch(name~, ..) {
          assert_eq(name, "0001_a")
        } else {
          raise e
        }
    }
  })
}

///|
async test "bootstrap stamps the full set on a fresh database" {
  @async.with_task_group(group => {
    let (db, executor) = open("moondark-mig-bootstrap.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    ignore(db.execute("DROP TABLE IF EXISTS moondark_migrations"))
    ignore(db.execute("DROP TABLE IF EXISTS moondark_migration_records"))
    ignore(db.execute("DROP TABLE IF EXISTS items"))
    let migrator = @migration.Migrator::new(
      conn=db.conn(),
      dialect=@migration.Dialect::Sqlite,
    )
    migrator.bootstrap(
      schema="CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT, price REAL DEFAULT 0);",
      migrations=two_migrations()[:],
    )
    assert_eq(migrator.up(two_migrations()[:]), [])
    try {
      migrator.bootstrap(schema="SELECT 1", migrations=two_migrations()[:])
      fail("expected NotFresh")
    } catch {
      e => assert_true(e is @migration.NotFresh)
    }
  })
}

///|
async test "load_dir picks dialect overrides" {
  let dir = "_build/mig-dir-test"
  @fs.mkdir(dir, permission=0o755, recursive=true, allow_exist=true)
  @fs.write_file(
    "\{dir}/0001_a.sql",
    b"CREATE TABLE a(x INTEGER);",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  @fs.write_file(
    "\{dir}/0001_a.postgres.sql",
    b"CREATE TABLE a(x BIGINT);",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  @fs.write_file(
    "\{dir}/0002_b.sql",
    b"CREATE TABLE b(x INTEGER);",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  @fs.write_file(
    "\{dir}/ignored.txt",
    b"not sql",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let sqlite_migs = @migration.Migration::load_dir(
    dir~,
    dialect=@migration.Dialect::Sqlite,
  )
  assert_eq(sqlite_migs.length(), 2)
  guard sqlite_migs[0] is @migration.Migration::Sql(sql~, ..) else {
    fail("expected Sql migration")
  }
  assert_true(sql.contains("x INTEGER"))
  let pg_migs = @migration.Migration::load_dir(
    dir~,
    dialect=@migration.Dialect::Postgres,
  )
  assert_eq(pg_migs.length(), 2)
  guard pg_migs[0] is @migration.Migration::Sql(sql~, ..) else {
    fail("expected Sql migration")
  }
  assert_true(sql.contains("x BIGINT"))
  @fs.write_file(
    "\{dir}/schema.sql",
    b"CREATE TABLE s(x INTEGER);",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  @fs.write_file(
    "\{dir}/schema.postgres.sql",
    b"CREATE TABLE s(x BIGINT);",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  guard @migration.load_schema(dir~, dialect=@migration.Dialect::Postgres)
    is Some(pg_schema) else {
    fail("expected schema")
  }
  assert_true(pg_schema.contains("x BIGINT"))
  guard @migration.load_schema(dir~, dialect=@migration.Dialect::Sqlite)
    is Some(sqlite_schema) else {
    fail("expected schema")
  }
  assert_true(sqlite_schema.contains("x INTEGER"))
}
