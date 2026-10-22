# moondark_mysql

MoonDark 的 MySQL 集成模块，基于 `moonbitstack/moonmysql`。

| 包 | 实现的 core 接口 | 公开 API |
|---|---|---|
| `xziheng/moondark_mysql/database` | `database/sql/driver` | `open_db`、`Driver` |
| `xziheng/moondark_mysql/sessions` | `sessions.SessionStore` | `MysqlSessionStore` |

按需导入子包，并显式写别名：

```text
import {
  "xziheng/moondark_mysql/database" @mysql_database,
  "xziheng/moondark_mysql/sessions" @mysql_sessions,
}
```

## database

```mbt nocheck
@async.with_task_group(group => {
  let (db, executor) = @mysql_database.open_db("mysql://root@127.0.0.1/app")
  group.spawn_bg(no_wait=true, () => executor.run())
  db.ready()
  defer db.close()
  let rows = db.query("SELECT ? + 1 AS n", params=[41])
  defer rows.close()
})
```

- `dsn` 支持 MySQL URI `mysql://user[:password]@host[:port]/database`（user、password、database 会做百分号解码）和 Go 风格 `user:password@tcp(host:port)/database`。端口默认 3306，空 host 默认 `127.0.0.1`；不支持查询参数和 Unix socket。
- 占位符用 MySQL 原生的 `?`；SQL 原样交给 MySQL。
- `ExecResult.rows_affected` 报告的是实际改变的行数，数据未变化的 `UPDATE` 返回 0。

## sessions

`MysqlSessionStore` 把会话存进 `sessions` 表（`table~` 可改名）。
表结构不在代码里创建：`sessions/schema.sql` 是现成的建表文件，
用 `mysql app < sessions/schema.sql` 或自己的迁移工具执行；
`table~` 改名时同步修改表名。

```sql
CREATE TABLE IF NOT EXISTS sessions (
    session_key VARCHAR(64) PRIMARY KEY,
    session_data TEXT NOT NULL,
    expires_at BIGINT NOT NULL
);
```

```mbt nocheck
let store = @mysql_sessions.MysqlSessionStore(db)
app.add_middleware(@sessions.middleware(store))
```
