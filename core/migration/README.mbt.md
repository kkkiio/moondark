# migration

`moondark/migration` 是离线就地迁移：版本清单写在代码里，执行
结果记在库中两张 bookkeeping 表里——`moondark_migrations`（已
应用集合 + 脚本 checksum）和 `moondark_migration_records`
（append-only 尝试日志）。

## Quick Start

```mbt check
///|
/// The manifest: which migrations the app offers, in code.
let migrations : Array[@migration.Migration] = [
  @migration.Migration::sql(
    name="v0001_todos",
    sql="CREATE TABLE todos (id INTEGER PRIMARY KEY, description TEXT)",
  ),
  @migration.Migration::run(name="v0002_seed_todos", run=conn => {
    ignore(conn.execute("INSERT INTO todos (description) VALUES ('hi')"))
  }),
]

///|
async test {
  @async.with_task_group(group => {
    let (db, executor) = @sqltest.FakeConnector::new().open_db()
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let conn = db.conn()
    defer conn.close()
    let migrator = @migration.Migrator::new(
      conn~,
      dialect=@migration.Dialect::Sqlite,
    )
    // pending = 清单 − applied set；从哪个版本开始不用告诉它，
    // DB 里的 bookkeeping 表就是答案。
    let applied = migrator.up(migrations[:])
    debug_inspect(
      applied,
      content=(
        #|["v0001_todos", "v0002_seed_todos"]
      ),
    )
  })
}
```

上面用的是 `sqltest` 的 `FakeConnector`——它只记录语句不执行
SQL，真实语义见 `examples/todo`。

## 每个操作做了什么

- **`up(migrations)`**：pending = 清单 − `moondark_migrations`，
  按名序逐条应用（每条一个事务，`use_tx=false` 关闭）。"从哪个
  版本开始"不是参数——applied set 就是当前位置。
- **`bootstrap(schema~, migrations~)`**：仅限空库——执行
  `schema.sql` 快照，再把传入迁移全部标记已应用；applied set
  非空抛 `NotFresh`。只传快照覆盖的部分（`.sql` 版本），`Run`
  版本留给 `up`。对应 Rails `db:schema:load` vs `db:migrate`，
  与 `up` 是显式分开的两个操作。
- **`pending` / `status`**：只读。`status` 附带 `applied_at`、
  `drifted`（已应用脚本与磁盘不符）、最近一次尝试状态。
- **两张 bookkeeping 表**：不是迁移管理的对象（迁移系统不能
  迁移自己）。每个操作开头 `ensure_tables()` 幂等创建它们——
  没有 init 命令，也不需要。DDL 在包内 `bookkeeping.<dialect>.sql`
  （构建时 `:embed` 进二进制），表名可用 `Migrator::new` 的
  `migrations_table~`/`records_table~` 改名。

**守护**：已应用 `.sql` 被改 → `ChecksumMismatch`；pending 插在
已应用历史中间 → `OutOfOrder`（历史只许尾部追加）；上次运行
中断残留 `started` 行 → `DirtyState`；迁移体失败 → `ApplyFailed`
（详情在 records 表）。

## 目录约定

一版本一目录（同时是 package）。

```text
migrations/                        # 聚合包：pub async fn migrations()
  schema.sql                       # bootstrap 快照（与版本目录平级）
  v0001_todos/                     # 版本名 = 目录名 = 包名
    moon.pkg  migration.mbt  up.sql    # SQL 版本（up.<dialect>.sql 覆盖）
  v0002_seed/
    moon.pkg  migration.mbt            # 代码版本：Migration::run
```

SQL 版本的 `migration()` 一行：`Migration::load(dir~, dialect~)`
按目录 basename 取名、选 `up.<dialect>.sql` > `up.sql`。
`load_schema(dir~, dialect~)` 读 `dir` 下的
`schema[.<dialect>].sql`。

`Migration::run` 没有可指纹的脚本（同 Django `RunPython` 盲区），
靠版本控制与 review 把关；`Run` 也不在快照覆盖范围内。

## 备注

- 集成包的建表语句（如 `moondark_sqlite/sessions` 的
  `schema.sql`）复制进自己的版本目录，框架不替应用建表。
- 要单二进制制品时用内置 `:embed` 把 `up.sql` 编成 `.mbt` 常量
  喂 `Migration::sql`——本包 `bookkeeping.<dialect>.sql` →
  `*_gen.mbt` 即范例。
- 完整接线示例：`examples/todo`。
