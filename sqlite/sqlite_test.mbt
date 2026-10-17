///|
async test "execute, query and value round trip" {
  let db = @moondark_sqlite.open_db("_build/moondark-sqlite-test.db")
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
}

///|
async test "with_transaction commits and rolls back" {
  let db = @moondark_sqlite.open_db("_build/moondark-sqlite-tx-test.db")
  defer db.close()
  ignore(db.execute("DROP TABLE IF EXISTS entries"))
  ignore(db.execute("CREATE TABLE entries(value INTEGER)"))
  db.with_transaction(tx => ignore(tx.execute("INSERT INTO entries VALUES (1)")))
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
}

///|
async test "session store over sqlite" {
  let db = @moondark_sqlite.open_db("_build/moondark-sqlite-sessions-test.db")
  defer db.close()
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
  json_inspect(loaded.to_model(), content={
    "key": "k1",
    "data": { "user": 1 },
    "expires_at": 2000000000,
  })
  loaded.set("user", Json::number(2))
  assert_true(store.update(loaded))
  guard store.get("k1") is Some(updated) else { fail("session not found") }
  assert_true(updated.to_model().data["user"] == Json::number(2))
  store.delete("k1")
  assert_true(store.get("k1") is None)
}
