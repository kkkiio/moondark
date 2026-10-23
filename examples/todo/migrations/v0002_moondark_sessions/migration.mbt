///|
/// v0002: the sessions table, folded in from
/// `KKKIIO/moondark_sqlite/sessions`'s `schema.sql` — integration
/// packages ship their DDL as example files; the app owns them as
/// versions like any other.
pub async fn migration() -> @migration.Migration {
  @migration.Migration::load(
    dir="migrations/v0002_moondark_sessions",
    dialect=@migration.Dialect::Sqlite,
  )
}
