# moondark_example_todo

Minimal todo list CLI demonstrating schema management with `xziheng/moondark/migration`.

## Quick Start

Run from this directory:

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
```

## Layout

```text
migrations/                         # Manifest package exporting migrations()
  moon.pkg
  migrations.mbt                    # Full migration list + snapshotted()
  schema.sql                        # Bootstrap snapshot of all .sql migrations
  v0001_todos/
    moon.pkg  migration.mbt  up.sql # Application table DDL
  v0002_moondark_sessions/
    moon.pkg  migration.mbt  up.sql # DDL copied from sqlite/sessions/schema.sql
  v0003_seed_todos/
    moon.pkg  migration.mbt         # Code migration via Migration::run
main.mbt                            # CLI entry point
app/app.mbt                         # load / migrate / status + todo operations
```
