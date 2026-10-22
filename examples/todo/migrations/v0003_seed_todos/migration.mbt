///|
/// v0003: a `Run` data migration — arbitrary MoonBit code on the
/// migrator's connection, for changes plain SQL cannot express.
/// `Run` bodies carry no checksum (same blind spot as Django's
/// `RunPython`): keep them self-contained and treat edits as
/// review-sensitive.
pub fn migration() -> @migration.Migration {
  @migration.Migration::run(name="v0003_seed_todos", run=conn => {
    ignore(
      conn.execute(
        "INSERT INTO todos (description) VALUES ('learn moondark migrations')",
      ),
    )
  })
}
