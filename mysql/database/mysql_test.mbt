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
