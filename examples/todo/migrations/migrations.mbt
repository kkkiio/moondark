///|
/// The migration manifest — the app's migrations list in code:
/// one `migration()` per version package, ordered by version name.
/// Adding a version means adding its package's `migration()` here
/// (and its `moon.pkg` import above); ordering is by migration name,
/// so the list position is documentation, not execution order.
pub async fn migrations() -> Array[@migration.Migration] {
  [
    @v0001_todos.migration(),
    @v0002_moondark_sessions.migration(),
    @v0003_seed_todos.migration(),
  ]
}

///|
/// The subset of `migrations()` covered by the `schema.sql`
/// snapshot — its `.sql` versions. `bootstrap` stamps exactly these;
/// `Run` versions stay pending for `up`.
pub async fn snapshotted() -> Array[@migration.Migration] {
  migrations().filter(mig => mig is @migration.Migration::Sql(..))
}
