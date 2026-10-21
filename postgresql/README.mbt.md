# moondark_postgresql

MoonDark 的 PostgreSQL 集成模块，基于 `moonbit-community/postgres`。

| 包 | 实现的 core 接口 | 公开 API |
|---|---|---|
| `xziheng/moondark_postgresql/database` | `database/sql/driver` | `open_db`、`Driver` |
| `xziheng/moondark_postgresql/sessions` | `sessions.SessionStore` | `PostgresSessionStore` |

按需导入子包，并显式写别名：

```text
import {
  "xziheng/moondark_postgresql/database" @postgresql_database,
  "xziheng/moondark_postgresql/sessions" @postgresql_sessions,
}
```

## database

```mbt nocheck
@async.with_task_group(group => {
  let (db, executor) = @postgresql_database.open_db("postgres://user:pass@localhost:5432/app?sslmode=disable")
  group.spawn_bg(no_wait=true, () => executor.run())
  db.ready()
  defer db.close()
  let rows = db.query("SELECT $1::int4 + 1 AS n", params=[41])
  defer rows.close()
})
```

DSN 为 `postgres://user[:password]@host[:port]/database[?params]`（或
`postgresql://`）。默认值：`localhost`、`5432`、`database = user`、
`sslmode=disable`、`application_name=moondark`。支持的参数：
`sslmode`（`disable`|`verify-ca`|`verify-full`）、`application_name`、
`hostaddr`、`connect_timeout_ms`、`channel_binding`、`sslrootcert`、
`options`、`keepalives`、`keepalives_idle`；其他参数抛出 `InvalidDsn`。

- 占位符用 PostgreSQL 原生的 `$1`、`$2`…；SQL 原样发给服务端，驱动不改写，jsonb 运算符（`?`、`?|`、`?&`）无需转义。
- 参数以文本格式发送，由 PostgreSQL 做类型转换，未标注类型的绑定对所有 `driver.Value` 都可用。
- `ExecResult.last_insert_id` 恒为 `None`，请用 `RETURNING`。
- 表示连接已失效的错误报告为 `driver.BadConn`，并在新的池连接上重试。

## sessions

`PostgresSessionStore` 把会话存进 `sessions` 表（`table~` 可改名）；`migrate` 建表。

```mbt nocheck
let store = @postgresql_sessions.PostgresSessionStore(db)
store.migrate()
app.add_middleware(@sessions.middleware(store))
```
