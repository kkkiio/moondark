///|
async test "execute, query and value round trip" {
  @async.with_task_group(group => {
    let dir = @fs.tmpdir(prefix="moondark-sqlite-test")
    let (db, executor) = @database.open_db("\{dir}/test.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    ignore(db.execute("DROP TABLE IF EXISTS items"))
    ignore(
      db.execute(
        "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT, price REAL, flag INTEGER, data BLOB, note TEXT)",
      ),
    )
    let result = db.execute(
      "INSERT INTO items (name, price, flag, data, note) VALUES (?, ?, ?, ?, ?)",
      params=["apple", 1.5, true, b"\x01\x02", @moondark_database.Value::Null],
    )
    assert_eq(result.rows_affected, Some(1))
    assert_eq(result.last_insert_id, Some(1))
    let rows = db
      .query_all("SELECT name, price, flag, data, note FROM items")
      .iter()

    guard rows.next() is Some(row) else { fail("expected one row") }
    assert_eq((row.get_name("name") : String), "apple")
    assert_eq((row.get_name("price") : Double), 1.5)
    assert_eq((row.get_name("flag") : Bool), true)
    assert_eq((row.get_name("data") : Bytes), b"\x01\x02")
    assert_eq((row.get_name("note") : String?), None)
    assert_true(rows.next() is None)
  })
}

///|
async test "batch_execute runs statements and keeps trigger bodies whole" {
  @async.with_task_group(group => {
    let dir = @fs.tmpdir(prefix="moondark-sqlite-script")
    let (db, executor) = @database.open_db("\{dir}/script.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    db.batch_execute(
      (
        #|DROP TABLE IF EXISTS src; DROP TABLE IF EXISTS audit;
        #|CREATE TABLE src(v TEXT);
        #|CREATE TABLE audit(v TEXT);
        #|-- the trigger body holds two `;`
        #|CREATE TRIGGER src_audit AFTER INSERT ON src BEGIN
        #|  INSERT INTO audit VALUES (new.v);
        #|  INSERT INTO audit VALUES (new.v || '!');
        #|END;
        #|INSERT INTO src VALUES ('a;b');
      ),
    )
    let rows = db.query_all("SELECT v FROM audit ORDER BY v").iter()

    guard rows.next() is Some(first) else { fail("expected two rows") }
    assert_eq((first.get_name("v") : String), "a;b")
    guard rows.next() is Some(second) else { fail("expected two rows") }
    assert_eq((second.get_name("v") : String), "a;b!")
    assert_true(rows.next() is None)
  })
}

///|
async test "with_transaction commits and rolls back" {
  @async.with_task_group(group => {
    let dir = @fs.tmpdir(prefix="moondark-sqlite-tx")
    let (db, executor) = @database.open_db("\{dir}/tx.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    ignore(db.execute("DROP TABLE IF EXISTS entries"))
    ignore(db.execute("CREATE TABLE entries(value INTEGER)"))
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
    let rows = db.query_all("SELECT value FROM entries ORDER BY value").iter()

    guard rows.next() is Some(row) else { fail("expected one row") }
    assert_eq((row.get_name("value") : Int64), 1)
    assert_true(rows.next() is None)
  })
}

///|
async test "every pooled SQLite connection enables foreign keys and lock waiting" {
  @async.with_task_group(group => {
    let dir = @fs.tmpdir(prefix="moondark-sqlite-pragmas")
    let (db, executor) = @database.open_db("\{dir}/pragmas.db", max_open=2)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    db.with_conn(first => {
      db.with_conn(second => {
        for conn in [first, second] {
          for
            (sql, column, expected) in [
              ("PRAGMA busy_timeout", "timeout", 5000L),
              ("PRAGMA foreign_keys", "foreign_keys", 1L),
            ] {
            let rows = conn.query_all(sql).iter()

            let row = rows.next().unwrap()
            let actual : Int64 = row.get_name(column)
            assert_eq(actual, expected)
          }
        }
      })
    })
  })
}

///|
async test "cached and scoped statements reset bindings and preserve nullable typed rows" {
  @async.with_task_group(group => {
    let (db, executor) = @database.open_db(":memory:", max_open=1)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    db.batch_execute(
      "CREATE TABLE typed (id INTEGER PRIMARY KEY, text TEXT, data BLOB, payload TEXT)",
    )
    let text = "hello"
    let bytes = b"abcd"
    ignore(
      db.execute("INSERT INTO typed VALUES (?, ?, ?, ?)", params=[
        1,
        text[1:4],
        bytes[1:3],
        ({ "value": 42 } : Json),
      ]),
    )
    ignore(
      db.execute("INSERT INTO typed VALUES (?, ?, ?, ?)", params=[
        2,
        (None : String?),
        (None : Bytes?),
        (None : Json?),
      ]),
    )
    db.with_conn(conn => {
      conn.with_prepared("SELECT text, data, payload FROM typed WHERE id = ?", stmt => {
        let first = stmt.query_one(params=[1])
        assert_eq((first.get_name("text") : String), "ell")
        assert_eq((first.get_name("data") : Bytes), b"bc")
        assert_eq((first.get_name("payload") : Json), { "value": 42 })
        let second = stmt.query_one(params=[2])
        assert_eq((second.get_name("text") : String?), None)
        assert_eq((second.get_name("data") : Bytes?), None)
        assert_eq((second.get_name("payload") : Json?), None)
        assert_true(stmt.query_opt(params=[3]) is None)
      })
    })
    assert_eq(db.stats().in_use, 0)
  })
}

///|
async test "cancelled SQLite transaction rolls back and reuses the only connection" {
  @async.with_task_group(group => {
    let (db, executor) = @database.open_db(":memory:", max_open=1)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    db.batch_execute("CREATE TABLE cancelled (id INTEGER)")
    let result = @async.with_timeout_opt(10, () => {
      db.with_transaction(tx => {
        ignore(tx.execute("INSERT INTO cancelled VALUES (1)"))
        tx.with_stream("SELECT id FROM cancelled", stream => {
          assert_true(stream.next() is Some(_))
          @async.sleep(100)
        })
      })
    })
    assert_true(result is None)
    assert_eq(db.query_all("SELECT id FROM cancelled").length(), 0)
    assert_eq(db.stats().in_use, 0)
    db.with_transaction(tx => tx.with_stream("SELECT 1", _ => tx.commit()))
    db.ping()
  })
}

///|
async test "connection scope resets manually opened transactions after cancellation" {
  @async.with_task_group(group => {
    let (db, executor) = @database.open_db(":memory:", max_open=1)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    db.batch_execute("CREATE TABLE manual (id INTEGER)")
    let result = @async.with_timeout_opt(10, () => {
      db.with_conn(conn => {
        conn.batch_execute("BEGIN; INSERT INTO manual VALUES (1)")
        @async.sleep(100)
      })
    })
    assert_true(result is None)
    assert_eq(db.query_all("SELECT id FROM manual").length(), 0)
    db.with_transaction(_ => ())
  })
}

///|
async test "cached SQLite statements recover after constraint errors" {
  @async.with_task_group(group => {
    let (db, executor) = @database.open_db(":memory:", max_open=1)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    db.batch_execute("CREATE TABLE unique_items (id INTEGER PRIMARY KEY)")
    ignore(db.execute("INSERT INTO unique_items VALUES (?)", params=[1]))
    try
      ignore(db.execute("INSERT INTO unique_items VALUES (?)", params=[1]))
    catch {
      _ => ()
    } noraise {
      _ => fail("expected constraint failure")
    }
    ignore(db.execute("INSERT INTO unique_items VALUES (?)", params=[2]))
    assert_eq(db.query_all("SELECT id FROM unique_items").length(), 2)
  })
}

///|
async test "finished SQLite streams release the connection before the callback returns" {
  @async.with_task_group(group => {
    let (db, executor) = @database.open_db(
      ":memory:",
      max_open=1,
      statement_cache_capacity=1,
    )
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    @async.with_timeout(1000, () => {
      db.with_conn(conn => {
        conn.with_stream("SELECT 1 AS n", stream => {
          stream.finish()
          assert_eq((conn.query_one("SELECT 2 AS n").get_name("n") : Int32), 2)
          conn.with_stream("SELECT 3 AS n", inner => {
            ignore(inner.collect())
            conn.ping()
          })
          assert_true(stream.next() is None)
        })
        conn.with_prepared("SELECT ? AS n", stmt => {
          stmt.with_stream(params=[4], stream => {
            stream.finish()
            assert_eq((stmt.query_one(params=[5]).get_name("n") : Int32), 5)
          })
        })
      })
      db.with_transaction(tx => {
        tx.with_stream("SELECT 6 AS n", stream => {
          stream.finish()
          assert_eq((tx.query_one("SELECT 7 AS n").get_name("n") : Int32), 7)
        })
      })
    })
    assert_eq(db.stats().in_use, 0)
  })
}
