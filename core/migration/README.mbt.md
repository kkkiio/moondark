# migration

In-place SQL and code database migrations tracked in the target database.

## Quick Start

```mbt check
///|
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
    let (db, executor) = @databasetest.FakeConnector::new().open_db()
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    db.with_conn(conn => {
      let migrator = @migration.Migrator::new(
        conn~,
        dialect=@migration.Dialect::Sqlite,
      )
      let applied = migrator.up(migrations[:])
      debug_inspect(
        applied,
        content=(
          #|["v0001_todos", "v0002_seed_todos"]
        ),
      )
    })
  })
}
```

## Directory Layout

Each migration lives in its own versioned package directory under `migrations/`:

```text
migrations/
  schema.sql                       # Optional schema snapshot for Migrator::bootstrap
  v0001_todos/
    moon.pkg  migration.mbt  up.sql
  v0002_seed/
    moon.pkg  migration.mbt
```

Use `Migration::load(dir~, dialect~)` to load `up.<dialect>.sql` (falling back to `up.sql`) and `load_schema(dir~, dialect~)` to load `schema.<dialect>.sql` (falling back to `schema.sql`). See `examples/todo` for a complete setup.
