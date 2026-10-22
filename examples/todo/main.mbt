///|
/// Entry point: parse the subcommand, open the database file and hand
/// off to `app`. Migrations live under `migrations/` next to this
/// directory — see `app.mbt` for the wiring.
async fn main {
  let matches = @argparse.Command(
    "todo",
    about="Todo list demonstrating moondark's migration package.",
    options=[
      OptionArg("db", long="db", about="SQLite database file", default_values=[
        "todo.db",
      ]),
    ],
    subcommands=[
      Command(
        "load",
        about="install migrations/schema.sql into a fresh database",
      ),
      Command("migrate", about="apply pending migrations"),
      Command("status", about="print migration status"),
      Command("add", about="add a todo", positionals=[
        PositionArg(
          "text",
          about="what needs doing",
          num_args=@argparse.ValueRange::single(),
        ),
      ]),
      Command("done", about="mark a todo done", positionals=[
        PositionArg(
          "id",
          about="todo id",
          num_args=@argparse.ValueRange::single(),
        ),
      ]),
      Command("list", about="list todos"),
    ],
    subcommand_required=true,
  ).parse()
  @async.with_task_group(group => {
    let (db, executor) = @sqlite_database.open_db(matches.values["db"][0])
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    match matches.subcommand {
      Some(("load", _)) => @app.load(db)
      Some(("migrate", _)) => @app.migrate(db)
      Some(("status", _)) => @app.print_status(db)
      Some(("add", sub)) => @app.add_todo(db, sub.values["text"][0])
      Some(("done", sub)) => @app.done_todo(db, sub.values["id"][0])
      _ => @app.list_todos(db)
    }
  })
}
