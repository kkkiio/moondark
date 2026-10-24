///|
/// The app's database-facing half: explicit `load` / `migrate` /
/// `status` wiring plus the todo operations. The migration manifest
/// lives in the `migrations` package; `schema.sql` sits inside it
/// next to the version packages.
const MIGRATIONS_DIR : String = "migrations"

///|
/// Install `migrations/schema.sql` into a fresh database and stamp
/// the covered migrations applied — the `db:schema:load` path.
/// `bootstrap` refuses (`NotFresh`) when the applied set is
/// non-empty: this is a fresh-install path, not a repair one.
pub async fn load(db : @database.DB) -> Unit {
  db.with_conn(conn => {
    let migrator = @migration.Migrator::new(
      conn~,
      dialect=@migration.Dialect::Sqlite,
    )
    guard @migration.load_schema(
        dir=MIGRATIONS_DIR,
        dialect=@migration.Dialect::Sqlite,
      )
      is Some(schema) else {
      fail("no migrations/schema.sql")
    }
    migrator.bootstrap(schema~, migrations=@migrations.snapshotted()[:])
    println("loaded schema.sql")
  })
}

///|
/// Apply the app's pending migrations in name order — the
/// `db:migrate` path. `Migrator` holds one pooled connection for the
/// whole run, so check it out and hand it back here.
pub async fn migrate(db : @database.DB) -> Unit {
  db.with_conn(conn => {
    let migrator = @migration.Migrator::new(
      conn~,
      dialect=@migration.Dialect::Sqlite,
    )
    let applied = migrator.up(@migrations.migrations()[:])
    if applied.is_empty() {
      println("nothing to do")
    } else {
      let names = applied.join(", ")
      println("applied: \{names}")
    }
  })
}

///|
/// Print `applied`/`pending`/`drifted` per migration, newest attempt
/// status included.
pub async fn print_status(db : @database.DB) -> Unit {
  db.with_conn(conn => {
    let migrator = @migration.Migrator::new(
      conn~,
      dialect=@migration.Dialect::Sqlite,
    )
    for s in migrator.status(@migrations.migrations()[:]) {
      let state = if s.drifted {
        "drifted"
      } else if s.applied {
        "applied"
      } else {
        "pending"
      }
      println("\{state}\t\{s.name}")
    }
  })
}

///|
pub async fn add_todo(db : @database.DB, text : String) -> Unit {
  ignore(
    db.execute("INSERT INTO todos (description) VALUES (?)", params=[text]),
  )
  println("added: \{text}")
}

///|
pub async fn done_todo(db : @database.DB, id : String) -> Unit {
  let result = db.execute("UPDATE todos SET done = 1 WHERE id = ?", params=[id])
  match result.rows_affected {
    Some(n) if n > 0 => println("done: \{id}")
    _ => println("no such todo: \{id}")
  }
}

///|
pub async fn list_todos(db : @database.DB) -> Unit {
  let rows = db.query_all("SELECT id, description, done FROM todos ORDER BY id")

  for row in rows {
    let id : Int64 = row.get_name("id")
    let done : Bool = row.get_name("done")
    let description : String = row.get_name("description")
    let mark = if !done { " " } else { "x" }
    println("\{id}. [\{mark}] \{description}")
  }
}
