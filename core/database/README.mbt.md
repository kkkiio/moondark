# database

Asynchronous SQL connection pool, transaction scopes, and typed row decoding for MoonDark (`KKKIIO/moondark/database`).

## Quick Start

```mbt check
///|
async fn _quick_start(connector : &@driver.Connector) -> Unit {
  @async.with_task_group(group => {
    let (db, executor) = @database.DB::create(connector)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()

    // Execute a write with native backend placeholders
    ignore(
      db.execute("INSERT INTO users (name, bio) VALUES ($1, $2)", params=[
        "alice",
        (None : String?),
      ]),
    )

    // Fetch a single row and decode columns by name or index
    let row = db.query_one("SELECT id, name, bio FROM users WHERE name = $1", params=[
      "alice",
    ])
    let id : Int64 = row.get(0)
    let name : String = row.get_name("name")
    let bio : String? = row.get_name("bio")
    ignore((id, name, bio))
  })
}
```

## Query APIs

Choose the completion method that matches your expected cardinality; the pool checks out and returns a connection automatically:

| Need | API |
| --- | --- |
| Exactly one row (`0` or `>1` raises `RowCount`) | `db.query_one(sql, params?)` |
| Zero or one row (`>1` raises `RowCount`) | `db.query_opt(sql, params?)` |
| All rows collected into `Array[Row]` | `db.query_all(sql, params?)` |
| Incremental row cursor (auto-drained on exit) | `db.with_stream(sql, params?, stream => ...)` |
| Side-effecting statement (`ExecResult`) | `db.execute(sql, params?)` |
| Multi-statement SQL script without parameters | `db.batch_execute(script)` |

## Transactions And Scoped Connections

`with_transaction` commits on normal return and rolls back under cancellation protection if the callback raises or is cancelled. `with_conn` pins a single physical connection for session-scoped state or prepared statements:

```mbt check
///|
async fn _tx_and_conn(db : @database.DB) -> Array[String] {
  db.with_transaction(tx => {
    ignore(
      tx.execute("UPDATE accounts SET balance = balance - $1 WHERE id = $2", params=[
        100, 1,
      ]),
    )
    ignore(
      tx.execute("UPDATE accounts SET balance = balance + $1 WHERE id = $2", params=[
        100, 2,
      ]),
    )
  })

  db.with_conn(conn => {
    conn.with_prepared("SELECT name FROM accounts WHERE id = $1", stmt => {
      let first : String = stmt.query_one(params=[1]).get_name("name")
      let second : String = stmt.query_one(params=[2]).get_name("name")
      [first, second]
    })
  })
}
```

## GenericClient

`DB`, `Conn`, and `Transaction` all implement `@database.GenericClient`, allowing repository functions to accept any execution context:

```mbt check
///|
async fn find_user_email(
  client : &@database.GenericClient,
  user_id : Int64,
) -> String? {
  match
    client.query_opt("SELECT email FROM users WHERE id = $1", params=[user_id]) {
    Some(row) => Some(row.get_name("email"))
    None => None
  }
}

///|
async fn _use_generic_client(db : @database.DB) -> Unit {
  ignore(find_user_email(db, 1))
  db.with_transaction(tx => ignore(find_user_email(tx, 1)))
}
```
