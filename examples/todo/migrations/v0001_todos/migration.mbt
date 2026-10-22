///|
/// v0001: the app's own todos table. SQL lives in this package's
/// `up.sql`; `Migration::load` resolves it (and any
/// `up.<dialect>.sql` override) and names the migration after this
/// directory.
pub async fn migration() -> @migration.Migration {
  @migration.Migration::load(
    dir="migrations/v0001_todos",
    dialect=@migration.Dialect::Sqlite,
  )
}
