# todo CLI 迁移生命周期

全新库上 `load` 装入 `schema.sql` 快照并 stamp 它覆盖的 `.sql`
版本；随后的 `migrate` 只跑快照覆盖不到的 `Run` 版本。

```mooncram
$ cd "$TESTDIR/.."
> rm -f test.db
> moondark_example_todo.exe --db test.db load
> moondark_example_todo.exe --db test.db migrate
> moondark_example_todo.exe --db test.db status
loaded schema.sql
applied: v0003_seed_todos
applied\tv0001_todos (escaped)
applied\tv0002_moondark_sessions (escaped)
applied\tv0003_seed_todos (escaped)
```

应用子命令照常工作。

```mooncram
$ cd "$TESTDIR/.."
> rm -f test.db
> moondark_example_todo.exe --db test.db migrate
> moondark_example_todo.exe --db test.db add "write docs"
> moondark_example_todo.exe --db test.db list
> moondark_example_todo.exe --db test.db done 2
> moondark_example_todo.exe --db test.db list
applied: v0001_todos, v0002_moondark_sessions, v0003_seed_todos
added: write docs
1. [ ] learn moondark migrations
2. [ ] write docs
done: 2
1. [ ] learn moondark migrations
2. [x] write docs
```

`migrate` 幂等：无 pending 时输出 `nothing to do`。

```mooncram
$ cd "$TESTDIR/.."
> rm -f test.db
> moondark_example_todo.exe --db test.db migrate
> moondark_example_todo.exe --db test.db migrate
> rm -f test.db
applied: v0001_todos, v0002_moondark_sessions, v0003_seed_todos
nothing to do
```

`load` 是全新库专用：applied set 非空时 `bootstrap` 抛
`NotFresh`（stderr），exit code 1（块的退出码即最后一条命令）。

```mooncram {output_stream: stderr}
$ cd "$TESTDIR/.."
> rm -f test.db
> moondark_example_todo.exe --db test.db migrate
> moondark_example_todo.exe --db test.db load
xziheng/moondark/migration.MigrationError.NotFresh
[1]
```

```mooncram
$ rm -f "$TESTDIR/../test.db"
```
