# moondark_postgresql

PostgreSQL driver for moondark's `database/sql` abstraction, built on
`moonbit-community/postgres`.

`open_db` accepts a standard postgres URL and returns a pooled `DB`
plus the `DBExecutor` that runs the pool's workers:

```mbt nocheck
@async.with_task_group(group => {
  let (db, executor) = @moondark_postgresql.open_db(
    "postgres://user:pass@localhost:5432/app?sslmode=disable",
  )
  group.spawn_bg(no_wait=true, () => executor.run())
  db.ready()
  defer db.close()
  let rows = db.query("SELECT $1::int4 + 1 AS n", params=[41])
  defer rows.close()
})
```

## DSN

`postgres://user[:password]@host[:port]/database[?params]` (or
`postgresql://`). Defaults: `localhost`, `5432`, `database = user`,
`sslmode=disable`, `application_name=moondark`. Supported parameters:
`sslmode` (`disable`|`verify-ca`|`verify-full`), `application_name`,
`hostaddr`, `connect_timeout_ms`, `channel_binding`, `sslrootcert`,
`options`, `keepalives`, `keepalives_idle`. Anything else raises
`InvalidDsn`.

## Notes

- Parameters are sent in text format; PostgreSQL performs the
  conversion, so `?`-style untyped binds work for every `driver.Value`
  (placeholders are still PostgreSQL `$1`, `$2`, …).
- `ExecResult.last_insert_id` is always `None`; use `RETURNING`.
- Errors that mean the connection is dead are reported as
  `driver.BadConn` and retried on a fresh pooled connection.
