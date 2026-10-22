///|
/// Loading migrations and the authoritative schema from disk.
///
/// Convention — a `migrations/` directory holding the bootstrap
/// snapshot next to one directory per migration version:
///   migrations/schema.sql               — authoritative bootstrap schema
///   migrations/schema.postgres.sql      — postgres-only schema override
///   migrations/v0001_init/              — one version directory
///     up.sql                            — generic migration script
///     up.postgres.sql                   — postgres-only override of up.sql
///
/// Version directories are MoonBit packages exposing a `migration()`
/// (SQL-only versions call `Migration::load`, code migrations build
/// `Migration::run`); the app lists them explicitly in code — that
/// list is the manifest, the directory is only a file store.

///|
/// Load a migration from its version directory `dir`; the migration
/// name is the directory's basename (`dir` may end in `/`).
/// `up.<dialect>.sql` wins over `up.sql`; files for other dialects
/// are ignored. `InvalidName` when the basename is not a valid
/// migration name; raises when neither script file exists.
pub async fn Migration::load(
  dir~ : String,
  dialect~ : Dialect,
  use_tx~ : Bool = true,
) -> Migration {
  let name = version_name(dir)
  let specific = join_path(dir, "up.\{dialect.suffix()}.sql")
  if @fs.exists(specific) {
    return Migration::sql(name~, sql=@fs.read_file(specific).text(), use_tx~)
  }
  Migration::sql(
    name~,
    sql=@fs.read_file(join_path(dir, "up.sql")).text(),
    use_tx~,
  )
}

///|
/// Read the authoritative schema file for `bootstrap` from `dir`
/// (the directory holding the version directories):
/// `schema.<dialect>.sql` wins over `schema.sql`; `None` when
/// neither exists.
pub async fn load_schema(dir~ : String, dialect~ : Dialect) -> String? {
  let specific = join_path(dir, "schema.\{dialect.suffix()}.sql")
  if @fs.exists(specific) {
    return Some(@fs.read_file(specific).text())
  }
  let generic = join_path(dir, "schema.sql")
  if @fs.exists(generic) {
    return Some(@fs.read_file(generic).text())
  }
  None
}

///|
/// The basename of `dir` (trailing `/` ignored), validated as a
/// migration name — the version name is the directory name.
fn version_name(dir : String) -> String raise {
  let mut end = dir.length()
  while end > 0 && dir[end - 1] == '/' {
    end -= 1
  }
  let mut start = end
  while start > 0 && dir[start - 1] != '/' {
    start -= 1
  }
  let name = dir[start:end].to_owned()
  if !is_migration_name(name) {
    raise InvalidName(name)
  }
  name
}

///|
fn join_path(dir : String, file : String) -> String {
  if dir.has_suffix("/") {
    "\{dir}\{file}"
  } else {
    "\{dir}/\{file}"
  }
}
