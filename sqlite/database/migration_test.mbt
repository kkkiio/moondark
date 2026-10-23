///|
async fn open(file : String) -> (@sql.DB, @sql.DBExecutor) {
  let dir = @fs.tmpdir(prefix="moondark-mig")
  @database.open_db("\{dir}/\{file}")
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
async test "Migration::load picks the dialect override in a version dir" {
  let dir = @fs.tmpdir(prefix="moondark-mig-dir")
  @fs.mkdir(
    "\{dir}/v0001_a",
    permission=0o755,
    recursive=true,
    allow_exist=true,
  )
  @fs.write_file(
    "\{dir}/v0001_a/up.sql",
    b"CREATE TABLE a(x INTEGER);",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  @fs.write_file(
    "\{dir}/v0001_a/up.postgres.sql",
    b"CREATE TABLE a(x BIGINT);",
    create_mode=@fs.CreateMode::CreateOrTruncate,
  )
  let sqlite_mig = @migration.Migration::load(
    dir="\{dir}/v0001_a",
    dialect=@migration.Dialect::Sqlite,
  )
  guard sqlite_mig is @migration.Migration::Sql(name~, sql~, ..) else {
    fail("expected Sql migration")
  }
  assert_eq(name, "v0001_a")
  assert_true(sql.contains("x INTEGER"))
  let pg_mig = @migration.Migration::load(
    dir="\{dir}/v0001_a",
    dialect=@migration.Dialect::Postgres,
  )
  guard pg_mig is @migration.Migration::Sql(sql~, ..) else {
    fail("expected Sql migration")
  }
  assert_true(sql.contains("x BIGINT"))
}

///|
async test "load_schema prefers the dialect override" {
  let dir = @fs.tmpdir(prefix="moondark-mig-dir")
  @fs.mkdir(dir, permission=0o755, recursive=true, allow_exist=true)
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

///|
async test "up rejects a pending migration inserted before the latest applied" {
  @async.with_task_group(group => {
    let (db, executor) = open("moondark-mig-order.db")
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
    ignore(migrator.up(two_migrations()[:]))
    // A late-added 0000 sorts before the already-applied 0002 —
    // history is append-only at the tail.
    let spliced = [
      @migration.Migration::sql(
        name="0000_spliced",
        sql="CREATE TABLE spliced(x INTEGER);",
      ),
      ..two_migrations(),
    ]
    try {
      ignore(migrator.up(spliced[:]))
      fail("expected OutOfOrder")
    } catch {
      e =>
        if e is @migration.OutOfOrder(name~, latest~) {
          assert_eq(name, "0000_spliced")
          assert_eq(latest, "0002_price")
        } else {
          raise e
        }
    }
    // And nothing was applied.
    assert_eq(count_rows(db, "SELECT name FROM moondark_migrations"), 2)
  })
}
