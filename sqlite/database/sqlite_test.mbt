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
      params=["apple", 1.5, true, b"\x01\x02", @driver.Value::Null],
    )
    assert_eq(result.rows_affected, Some(1))
    assert_eq(result.last_insert_id, Some(1))
    let rows = db.query("SELECT name, price, flag, data, note FROM items")
    defer rows.close()
    guard rows.next() is Some(row) else { fail("expected one row") }
    debug_inspect(
      row,
      content=(
        #|{
        #|  columns: <ArrayView: ["name", "price", "flag", "data", "note"]>,
        #|  values: <ArrayView:
        #|    [
        #|      String("apple"),
        #|      Double(1.5),
        #|      Int64(1),
        #|      Bytes(<Bytes: [0x01, 0x02]>),
        #|      Null,
        #|    ]>,
        #|}
      ),
    )
    assert_true(rows.next() is None)
  })
}

///|
async test "execute_script runs statements and keeps trigger bodies whole" {
  @async.with_task_group(group => {
    let dir = @fs.tmpdir(prefix="moondark-sqlite-script")
    let (db, executor) = @database.open_db("\{dir}/script.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let conn = db.conn()
    defer conn.close()
    conn.execute_script(
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
    let rows = db.query("SELECT v FROM audit ORDER BY v")
    defer rows.close()
    guard rows.next() is Some(first) else { fail("expected two rows") }
    assert_true(first.get("v") is Some(String("a;b")))
    guard rows.next() is Some(second) else { fail("expected two rows") }
    assert_true(second.get("v") is Some(String("a;b!")))
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
    let rows = db.query("SELECT value FROM entries ORDER BY value")
    defer rows.close()
    guard rows.next() is Some(row) else { fail("expected one row") }
    assert_true(row.get("value") is Some(Int64(1)))
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
    let first = db.conn()
    defer first.close()
    let second = db.conn()
    defer second.close()
    for conn in [first, second] {
      for
        (sql, column, expected) in [
          ("PRAGMA busy_timeout", "timeout", 5000L),
          ("PRAGMA foreign_keys", "foreign_keys", 1L),
        ] {
        let rows = conn.query(sql)
        defer rows.close()
        let row = rows.next().unwrap()
        guard row.get(column) is Some(Int64(actual)) else {
          fail("Missing pragma value")
        }
        assert_eq(actual, expected)
      }
    }
  })
}
