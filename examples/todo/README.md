# moondark_example_todo

一个最小的 todo list CLI，演示典型 MoonDark 应用如何用
`moondark/migration` 管理数据库 schema：一版本一目录
（同时是一个 package）、代码即 `migrations` 清单、显式的
`load` / `migrate` 两条路径，以及怎么把集成包附带的
`schema.sql` 折进自己的版本目录。

## 结构

```text
migrations/                         # 聚合包：导出 migrations() 清单
  moon.pkg                          # import 三个版本包
  migrations.mbt                    # 清单 + snapshotted()
  schema.sql                        # bootstrap 快照 = 全部 .sql 版本的并集
  v0001_todos/
    moon.pkg  migration.mbt  up.sql # 应用自己的表
  v0002_moondark_sessions/
    moon.pkg  migration.mbt  up.sql # 折进 sqlite/sessions 的 schema.sql
  v0003_seed_todos/
    moon.pkg  migration.mbt         # 代码版本：Migration::run
main.mbt                            # CLI 入口（argparse 子命令分发）
app/app.mbt                         # load/migrate/status 接线 + todo 操作
app/app_test.mbt                    # 断言 v0002 与集成包 schema.sql 同步
```

## 运行

在本目录执行（`moon run` 的工作目录即模块根目录）：

```console
$ moon run . -- --db _build/todo.db load
loaded schema.sql
$ moon run . -- --db _build/todo.db migrate
applied: v0003_seed_todos
$ moon run . -- --db _build/todo.db status
applied	v0001_todos
applied	v0002_moondark_sessions
applied	v0003_seed_todos
$ moon run . -- --db _build/todo.db list
1. [ ] learn moondark migrations
$ moon run . -- --db _build/todo.db add "write the example"
added: write the example
$ moon run . -- --db _build/todo.db done 2
done: 2
$ moon run . -- --db _build/todo.db list
1. [ ] learn moondark migrations
2. [x] write the example
$ moon run . -- --db _build/todo.db migrate
nothing to do
$ moon run . -- --db _build/todo.db load
xziheng/moondark/migration.MigrationError.NotFresh
```

- `load` 只在全新库上跑：一次装入 `schema.sql` 并把快照覆盖的
  `.sql` 版本标记已应用，随后 `migrate` 只跑剩下的
  `v0003_seed_todos`（代码版本不在快照覆盖范围内）。非空库
  上 `bootstrap` 抛 `NotFresh`——它不是修复路径。
- `migrate` 也可以在全新库上跑（跳过 `load`）：按序重放全部
  版本，与 `load` 殊途同归；已有库则只应用 pending。
- `--db` 指定 SQLite 文件（默认 `todo.db`）。

## 这个示例演示的点

- **一版本一 package**：`vNNNN_x/` 目录装 `moon.pkg` +
  `migration.mbt` + `up.sql`，版本名即目录名；每个代码迁移的
  依赖在自己的 `moon.pkg` 里声明，不污染 app。
- **migrations.mbt 即清单**：`migrations/migrations.mbt` 显式
  列出各版本包的 `migration()`，编译期固定；顺序由名字字典序
  决定。
- **显式的 load vs migrate**：类 Rails `db:schema:load` /
  `db:migrate`，不做自动判定。
- **折进集成包的 DDL**：集成包不替你建表（包内只有 `schema.sql`
  示例文件），把需要的 `CREATE TABLE` 复制成自己的版本
  （`v0002_moondark_sessions/up.sql`）；`app/app_test.mbt` 断言它
  与集成包 DDL 保持同步。
- **尾部追加**：`up` 拒绝排在最新已应用名之前的 pending 迁移
  （`OutOfOrder`）；中断残留 `started` 行抛 `DirtyState`；改动
  已应用 `.sql` 抛 `ChecksumMismatch`。

换 Postgres/MySQL 时把 `Dialect` 换掉、为受方言影响的版本加
`up.<dialect>.sql` 覆盖和 `schema.<dialect>.sql` 快照即可，接线
代码不变。
