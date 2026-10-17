///|
/// Start a throwaway postgres container, open a `DB` against it and run
/// `f` with the pool executor running. Both the pool and the container
/// are cleaned up when `f` returns.
async fn[T] run_db(f : async (@sql.DB) -> T, max_open~ : Int32 = 10) -> T {
  let pg = @postgres.run()
  defer pg.cleanup()
  let dsn = pg.connection_string(ssl_mode="disable")
  @async.with_task_group(group => {
    let (db, executor) = @moondark_postgresql.open_db(dsn, max_open~)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    f(db)
  })
}

///|
test "malformed DSNs are rejected" {
  try (ignore(@moondark_postgresql.open_db("sqlite3://x")) : Unit) catch {
    @moondark_postgresql.InvalidDsn(_) => ()
    _ => fail("expected InvalidDsn")
  } noraise {
    _ => fail("expected InvalidDsn")
  }
  try
    (ignore(@moondark_postgresql.open_db("postgres://h/db?bogus=1")) : Unit)
  catch {
    @moondark_postgresql.InvalidDsn(_) => ()
    _ => fail("expected InvalidDsn")
  } noraise {
    _ => fail("expected InvalidDsn")
  }
}

///|
async test "execute, query and value round trip" {
  run_db(db => {
    let ddl = db.execute(
      "CREATE TABLE items(id INT4 PRIMARY KEY, name TEXT, price FLOAT8, flag BOOL, data BYTEA, note TEXT)",
    )
    // DDL command tags carry no row count.
    assert_eq(ddl.rows_affected, None)
    let result = db.execute(
      "INSERT INTO items (id, name, price, flag, data, note) VALUES ($1, $2, $3, $4, $5, $6)",
      params=[1, "apple", 1.5, true, b"\x01\x02", @driver.Value::Null],
    )
    assert_eq(result.rows_affected, Some(1))
    // PostgreSQL has no lastrowid.
    assert_eq(result.last_insert_id, None)
    let rows = db.query("SELECT id, name, price, flag, data, note FROM items")
    defer rows.close()
    guard rows.next() is Some(row) else { fail("expected one row") }
    assert_true(row.get("id") is Some(Int64(1)))
    assert_true(row.get("name") is Some(String("apple")))
    assert_true(row.get("price") is Some(Double(1.5)))
    assert_true(row.get("flag") is Some(Bool(true)))
    assert_true(row.get("data") is Some(Bytes(b"\x01\x02")))
    assert_true(row.get("note") is Some(Null))
    assert_true(rows.next() is None)
  })
}

///|
async test "with_transaction commits and rolls back" {
  run_db(db => {
    ignore(db.execute("CREATE TABLE entries(value INT4)"))
    db.with_transaction(tx => {
      ignore(tx.execute("INSERT INTO entries VALUES ($1)", params=[1]))
    })
    try
      (
        db.with_transaction(tx => {
          ignore(tx.execute("INSERT INTO entries VALUES ($1)", params=[2]))
          fail("rollback")
        }) : Unit)
    catch {
      _ => ()
    } noraise {
      _ => fail("expected the transaction to propagate the error")
    }
    let rows = db.query("SELECT value FROM entries ORDER BY value")
    defer rows.close()
    guard rows.next() is Some(row) else { fail("expected one row") }
    assert_true(row.get("value") is Some(Int64(1)))
    assert_true(rows.next() is None)
  })
}

///|
async test "errors propagate without killing the connection" {
  run_db(db => {
    // A syntax error surfaces at prepare time; the connection survives.
    try (db.execute("SELEC bogus") : @driver.ExecResult) catch {
      _ => ()
    } noraise {
      _ => fail("expected a syntax error")
    }
    // A server error raised mid-stream leaves a reusable connection too.
    let rows = db.query("SELECT 1 / 0")
    try (rows.next() : @sql.Row?) catch {
      _ => ()
    } noraise {
      _ => fail("expected a division-by-zero error")
    }
    let rows = db.query("SELECT 42 AS answer")
    defer rows.close()
    guard rows.next() is Some(row) else { fail("expected one row") }
    assert_true(row.get("answer") is Some(Int64(42)))
  })
}

///|
async test "session store over postgresql" {
  run_db(db => {
    let store = @db.DBSessionStore::DBSessionStore(db)
    store.migrate()
    store.delete("k1")
    let session = @sessions.Session::of_model(@sessions.SessionModel::{
      key: "k1",
      data: { "user": Json::number(1) },
      expires_at: 2_000_000_000,
    })
    assert_true(store.create(session))
    assert_false(store.create(session))
    guard store.get("k1") is Some(loaded) else { fail("session not found") }
    let model = loaded.to_model()
    assert_eq(model.key, "k1")
    assert_eq(model.expires_at, 2_000_000_000)
    assert_true(model.data["user"] == Json::number(1))
    loaded.set("user", Json::number(2))
    assert_true(store.update(loaded))
    guard store.get("k1") is Some(updated) else { fail("session not found") }
    assert_true(updated.to_model().data["user"] == Json::number(2))
    store.delete("k1")
    assert_true(store.get("k1") is None)
  })
}

///|
async test "concurrent queries serialize on pool slots" {
  run_db(max_open=2, db => {
    let results = @async.all(
      [1, 2, 3, 4, 5, 6].map(n => {
        () => {
          let rows = db.query("SELECT $1::int4 * 10 AS v", params=[n])
          defer rows.close()
          guard rows.next() is Some(row) else { fail("expected a row") }
          match row.get("v") {
            Some(@driver.Value::Int64(v)) => v.to_int()
            _ => fail("unexpected value")
          }
        }
      }),
      max_concurrent=6,
    )
    assert_eq(results, [10, 20, 30, 40, 50, 60])
  })
}
