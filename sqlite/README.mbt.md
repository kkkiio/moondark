# moondark_sqlite

MoonDark 的 SQLite 集成模块，基于 `moonbit-community/sqlite3`。

| 包 | 实现的 core 接口 | 公开 API |
|---|---|---|
| `xziheng/moondark_sqlite/database` | `database/sql/driver` | `open_db`、`Driver` |
| `xziheng/moondark_sqlite/sessions` | `sessions.SessionStore` | `SqliteSessionStore` |

按需导入子包，并显式写别名：

```text
import {
  "xziheng/moondark_sqlite/database" @sqlite_database,
  "xziheng/moondark_sqlite/sessions" @sqlite_sessions,
}
```

## database

```mbt nocheck
@async.with_task_group(group => {
  let (db, executor) = @sqlite_database.open_db("app.db")
  group.spawn_bg(no_wait=true, () => executor.run())
  db.ready()
  defer db.close()
  let rows = db.query("SELECT ? + 1 AS n", params=[41])
  defer rows.close()
})
```

- `dsn` 是传给 `sqlite3_open_v2` 的文件名。每个池连接打开 `":memory:"` 都会得到独立的私有库，需要共享状态时用 `max_open=1` 或文件。
- 占位符用 SQLite 原生的 `?`；SQL 原样交给 SQLite。
- `Conn::execute_script` 按 SQLite 词法拆分语句并逐条提交，触发器体保持完整。

## sessions

`SqliteSessionStore` 把会话存进 `sessions` 表（`table~` 可改名）。
表结构不在代码里创建：`sessions/schema.sql` 是现成的建表文件，
用 `sqlite3 app.db < sessions/schema.sql`、`Conn::execute_script`
或自己的迁移工具执行；`table~` 改名时同步修改表名。

```sql
CREATE TABLE IF NOT EXISTS sessions (
    session_key VARCHAR(64) PRIMARY KEY,
    session_data TEXT NOT NULL,
    expires_at BIGINT NOT NULL
);
```

```mbt nocheck
let store = @sqlite_sessions.SqliteSessionStore(db)
app.add_middleware(@sessions.middleware(store))
```
