///|
async test "execute, query and value round trip" {
  @async.with_task_group(group => {
    let container = @mysql.run()
    defer container.cleanup()
    // Go-style DSN: user:pass@tcp(host:port)/db
    let (db, executor) = @database.open_db(container.dsn())
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    db.ping()
    ignore(db.execute("DROP TABLE IF EXISTS items"))
    ignore(
      db.execute(
        "CREATE TABLE items(id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255), price DOUBLE, flag TINYINT(1), data BLOB, note TEXT)",
      ),
    )
    let result = db.execute(
      "INSERT INTO items (name, price, flag, data, note) VALUES (?, ?, ?, ?, ?)",
      params=["apple", 1.5, true, b"\x01\x02", @driver.Value::Null],
    )
    assert_eq(result.rows_affected, Some(1))
    assert_eq(result.last_insert_id, Some(1))
    let rows = db.query("SELECT name, price, flag, data, note FROM items")
    defer rows.close()
    guard rows.next() is Some(row) else { fail("expected one row") }
    assert_true(row.get("name") is Some(String("apple")))
    guard row.get("price") is Some(Double(price)) else {
      fail("expected Double price")
    }
    assert_eq(price, 1.5)
    // MySQL has no native boolean: TINYINT(1) reads back as an integer.
    assert_true(row.get("flag") is Some(Int64(1)))
    guard row.get("data") is Some(Bytes(data)) else {
      fail("expected Bytes data")
    }
    assert_eq(data, b"\x01\x02")
    assert_true(row.get("note") is Some(Null))
    assert_true(rows.next() is None)
    // A server-side syntax error must not poison the pooled connection.
    let mut syntax_failed = false
    ignore(db.execute("SELEC nonsense")) catch {
      _ => syntax_failed = true
    }
    assert_true(syntax_failed)
    let recovered = db.query("SELECT 1")
    defer recovered.close()
    guard recovered.next() is Some(row2) else {
      fail("expected the connection to survive a syntax error")
    }
    assert_true(row2.get("1") is Some(Int64(1)))
  })
}

///|
async test "with_transaction commits and rolls back" {
  @async.with_task_group(group => {
    let container = @mysql.run()
    defer container.cleanup()
    // URI DSN: mysql://user:pass@host:port/db
    let (db, executor) = @database.open_db(container.connection_string())
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    ignore(db.execute("DROP TABLE IF EXISTS entries"))
    ignore(db.execute("CREATE TABLE entries(value BIGINT)"))
    db.with_transaction(tx => {
      ignore(tx.execute("INSERT INTO entries VALUES (1)"))
    })
    try
      (
        db.with_transaction(tx => {
          ignore(tx.execute("INSERT INTO entries VALUES (2)"))
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
async test "timestamp round trips through DATETIME" {
  @async.with_task_group(group => {
    let container = @mysql.run()
    defer container.cleanup()
    let (db, executor) = @database.open_db(container.dsn())
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    ignore(
      db.execute(
        "CREATE TABLE events(id INT PRIMARY KEY, at DATETIME(6), ts TIMESTAMP(6) NULL)",
      ),
    )
    // Binary protocol carries MYSQL_TIME both ways: the instant written is
    // the instant read back (DATETIME/TIMESTAMP have no zone; decoded as UTC).
    let moment = @time.ZonedDateTime::from_unix_second(
      1_700_000_000,
      nanosecond=123_456_000,
      zone=@time.utc_zone,
    )
    ignore(
      db.execute("INSERT INTO events VALUES (1, ?, ?)", params=[
        @driver.Value::Timestamp(moment),
        @driver.Value::Timestamp(moment),
      ]),
    )
    let rows = db.query("SELECT at, ts FROM events WHERE id = 1")
    defer rows.close()
    guard rows.next() is Some(row) else { fail("expected one row") }
    guard row.get("at") is Some(Timestamp(at)) else {
      fail("expected Timestamp for DATETIME")
    }
    guard row.get("ts") is Some(Timestamp(ts)) else {
      fail("expected Timestamp for TIMESTAMP")
    }
    for zdt in [at, ts] {
      assert_eq(zdt.to_unix_second(), 1_700_000_000)
      assert_eq(zdt.nanosecond(), 123_456_000)
    }
  })
}

///|
async test "execute_script runs multi-statement scripts" {
  @async.with_task_group(group => {
    let container = @mysql.run()
    defer container.cleanup()
    let (db, executor) = @database.open_db(container.dsn())
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    // CLIENT_MULTI_STATEMENTS is negotiated at connect, so a checked-out
    // connection can run a whole script (the shape migrations use).
    let conn = db.conn()
    defer conn.close()
    conn.execute_script(
      "CREATE TABLE a(x INT); INSERT INTO a VALUES (1); INSERT INTO a VALUES (2)",
    )
    let rows = conn.query("SELECT x FROM a ORDER BY x")
    defer rows.close()
    guard rows.next() is Some(row) else { fail("expected row 1") }
    assert_true(row.get("x") is Some(Int64(1)))
    guard rows.next() is Some(row2) else { fail("expected row 2") }
    assert_true(row2.get("x") is Some(Int64(2)))
    assert_true(rows.next() is None)
  })
}

///|
async test "cached statements survive pool round trips" {
  @async.with_task_group(group => {
    let container = @mysql.run()
    defer container.cleanup()
    // One pooled connection: every reacquisition returns it to idle and
    // reset_session runs on the next checkout, so the prepared statement
    // must survive both Rows::close and the reset.
    let (db, executor) = @database.open_db(
      container.dsn(),
      max_idle=1,
      max_open=1,
    )
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let stmt = db.prepare("SELECT ? AS v")
    defer stmt.close()
    for expected = 1L; expected <= 3L; expected = expected + 1 {
      let rows = stmt.query(params=[@driver.Value::Int64(expected)])
      guard rows.next() is Some(row) else { fail("expected a row") }
      assert_true(row.get("v") is Some(Int64(v)) && v == expected)
      rows.close()
    }
  })
}

///|
async test "concurrent queries share a bounded pool" {
  @async.with_task_group(group => {
    let container = @mysql.run()
    defer container.cleanup()
    let (db, executor) = @database.open_db(
      container.connection_string(),
      max_open=3,
    )
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    // Six queries racing three pooled connections.
    let tasks : Array[async () -> Int64] = []
    for i in 1..<=6 {
      tasks.push(() => {
        let rows = db.query("SELECT ? AS v", params=[i])
        defer rows.close()
        guard rows.next() is Some(row) else { fail("expected a row") }
        guard row.get("v") is Some(Int64(v)) else { fail("expected Int64") }
        v
      })
    }
    let results = @async.all(tasks[:])
    assert_eq(results, [1, 2, 3, 4, 5, 6].map(fn(i) { i.to_int64() }))
    // The pool opened no more than max_open connections, and at least one
    // caller had to wait for a connection to be released.
    assert_true(db.stats().open <= 3)
    assert_true(db.stats().wait_count > 0)
  })
}
