///|
/// Start a throwaway postgres container, open a `DB` against it and run
/// `f` with the pool executor running. Both the pool and the container
/// are cleaned up when `f` returns.
async fn[T] run_db(
  f : async (@moondark_database.DB) -> T,
  max_open~ : Int32 = 10,
) -> T {
  let pg = @postgres.run()
  defer pg.cleanup()
  let dsn = pg.connection_string(ssl_mode="disable")
  @async.with_task_group(group => {
    let (db, executor) = @database.open_db(dsn, max_open~)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    f(db)
  })
}

///|
test "malformed DSNs are rejected" {
  try (ignore(@database.open_db("sqlite3://x")) : Unit) catch {
    @database.InvalidDsn(_) => ()
    _ => fail("expected InvalidDsn")
  } noraise {
    _ => fail("expected InvalidDsn")
  }
  try (ignore(@database.open_db("postgres://h/db?bogus=1")) : Unit) catch {
    @database.InvalidDsn(_) => ()
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
      params=[
        1,
        "apple",
        1.5,
        true,
        b"\x01\x02",
        @moondark_database.Value::Null,
      ],
    )
    assert_eq(result.rows_affected, Some(1))
    // PostgreSQL has no lastrowid.
    assert_eq(result.last_insert_id, None)
    let rows = db
      .query_all("SELECT id, name, price, flag, data, note FROM items")
      .iter()

    guard rows.next() is Some(row) else { fail("expected one row") }
    assert_eq((row.get_name("id") : Int64), 1)
    assert_eq((row.get_name("name") : String), "apple")
    assert_eq((row.get_name("price") : Double), 1.5)
    assert_eq((row.get_name("flag") : Bool), true)
    assert_eq((row.get_name("data") : Bytes), b"\x01\x02")
    assert_eq((row.get_name("note") : String?), None)
    assert_true(rows.next() is None)
  })
}

///|
async test "connection setup errors preserve PostgreSQL SQLSTATE" {
  let pg = @postgres.run()
  defer pg.cleanup()
  let dsn = pg.connection_string(ssl_mode="disable")
  let missing_database = dsn.replace(
    old="/" + @percent.encode(pg.database()) + "?",
    new="/moondark_missing?",
  )
  let wrong_password = dsn.replace(
    old=":" + @percent.encode(pg.password()) + "@",
    new=":wrong_password@",
  )
  for (dsn, code) in [(missing_database, "3D000"), (wrong_password, "28P01")] {
    @async.with_task_group(group => {
      let (db, executor) = @database.open_db(dsn, max_open=1)
      group.spawn_bg(no_wait=true, () => executor.run())
      db.ready()
      defer db.close()
      try db.ping() catch {
        @client.ClientError::Database(error) =>
          assert_eq(error.code, Some(code))
        error => fail("expected PostgreSQL error, got \{error}")
      } noraise {
        _ => fail("expected connection setup failure")
      }
      assert_eq(db.stats().open, 0)
      assert_eq(db.stats().in_use, 0)
    })
  }
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
    let rows = db.query_all("SELECT value FROM entries ORDER BY value").iter()

    guard rows.next() is Some(row) else { fail("expected one row") }
    assert_eq((row.get_name("value") : Int64), 1)
    assert_true(rows.next() is None)
  })
}

///|
async test "errors propagate without killing the connection" {
  run_db(db => {
    // A syntax error surfaces at prepare time; the connection survives.
    try (db.execute("SELEC bogus") : @moondark_database.ExecResult) catch {
      _ => ()
    } noraise {
      _ => fail("expected a syntax error")
    }
    // A server error raised mid-stream leaves a reusable connection too.
    try (db.query_opt("SELECT 1 / 0") : @moondark_database.Row?) catch {
      _ => ()
    } noraise {
      _ => fail("expected a division-by-zero error")
    }
    let rows = db.query_all("SELECT 42 AS answer").iter()

    guard rows.next() is Some(row) else { fail("expected one row") }
    assert_eq((row.get_name("answer") : Int64), 42)
  })
}

///|
async test "concurrent queries serialize on pool slots" {
  run_db(max_open=2, db => {
    let results = @async.all(
      [1, 2, 3, 4, 5, 6].map(n => {
        () => {
          let rows = db
            .query_all("SELECT $1::int4 * 10 AS v", params=[n])
            .iter()

          guard rows.next() is Some(row) else { fail("expected a row") }
          (row.get_name("v") : Int32)
        }
      }),
      max_concurrent=6,
    )
    assert_eq(results, [10, 20, 30, 40, 50, 60])
  })
}

///|
async test "cancellation drains PostgreSQL protocol and rolls back before reuse" {
  run_db(max_open=1, db => {
    db.batch_execute("CREATE TABLE cancelled (id INT4)")
    @async.with_timeout(
      30_000,
      error=Failure("PostgreSQL cancellation did not complete"),
      () => {
        @async.with_task_group(group => {
          let ready : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
          let blocked : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
          let task = group.spawn(() => {
            db.with_transaction(tx => {
              ignore(
                tx.execute("INSERT INTO cancelled VALUES ($1)", params=[1]),
              )
              tx.with_prepared("SELECT id FROM cancelled", stmt => {
                stmt.with_stream(stream => {
                  assert_true(stream.next() is Some(_))
                  ready.put(())
                  blocked.get()
                })
              })
            })
          })
          ready.get()
          task.cancel()
          try task.wait() catch {
            @async.WaitedTaskAlreadyCancelled => ()
            error => raise error
          } noraise {
            _ => fail("expected the stream task to be cancelled")
          }
        })
      },
    )
    assert_eq(db.query_all("SELECT id FROM cancelled").length(), 0)
    db.with_transaction(tx => {
      tx.with_stream("SELECT generate_series(1, 10)", _ => tx.commit())
    })
    let row = db.query_one("SELECT $1::jsonb AS payload, $2::text AS text", params=[
      ({ "value": 42 } : Json),
      (None : String?),
    ])
    assert_eq((row.get_name("payload") : Json), { "value": 42 })
    assert_eq((row.get_name("text") : String?), None)
    assert_eq(db.stats().in_use, 0)
  })
}

///|
async test "finished PostgreSQL streams release their operation permit" {
  run_db(max_open=1, db => {
    @async.with_timeout(
      30_000,
      error=Failure("PostgreSQL connection did not become ready"),
      () => db.ping(),
    )
    let mut stage = "acquiring the warmed connection"
    @async.with_timeout(30_000, () => {
      db.with_conn(conn => {
        stage = "starting the connection stream"
        conn.with_stream("SELECT generate_series(1, 3) AS n", stream => {
          stage = "finishing the connection stream"
          stream.finish()
          stage = "pinging after finishing the connection stream"
          conn.ping()
          stage = "querying after finishing the connection stream"
          assert_eq((conn.query_one("SELECT 4 AS n").get_name("n") : Int32), 4)
        })
        stage = "preparing a statement"
        conn.with_prepared("SELECT $1::int4 AS n", stmt => {
          stage = "starting the prepared statement stream"
          stmt.with_stream(params=[5], stream => {
            stage = "finishing the prepared statement stream"
            stream.finish()
            stage = "querying after finishing the prepared statement stream"
            assert_eq((stmt.query_one(params=[6]).get_name("n") : Int32), 6)
          })
          stage = "closing the prepared statement"
        })
      })
      stage = "starting a transaction"
      db.with_transaction(tx => {
        stage = "starting the transaction stream"
        tx.with_stream("SELECT 7 AS n", stream => {
          stage = "finishing the transaction stream"
          stream.finish()
          stage = "querying after finishing the transaction stream"
          assert_eq((tx.query_one("SELECT 8 AS n").get_name("n") : Int32), 8)
        })
        stage = "committing the transaction"
      })
    }) catch {
      @async.TimeoutError =>
        fail("PostgreSQL stream reuse timed out while \{stage}")
      error => raise error
    }
    assert_eq(db.stats().in_use, 0)
  })
}
