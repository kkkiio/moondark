///|
/// Loading migrations and the authoritative schema from a directory.
///
/// Convention:
///   migrations/0001_init.sql          — generic migration
///   migrations/0001_x.postgres.sql    — postgres-only override of 0001_x
///   schema.sql                        — authoritative schema for bootstrap
///   schema.postgres.sql               — postgres-only schema override

///|
/// Load `.sql` migrations from `dir` sorted by name. For each
/// migration name a dialect-specific `NNNN_x.<dialect>.sql` file wins
/// over the generic `NNNN_x.sql`; files for other dialects are
/// skipped entirely.
pub async fn Migration::load_dir(
  dir~ : String,
  dialect~ : Dialect,
  use_tx~ : Bool = true,
) -> Array[Migration] {
  let names = @fs.readdir(
    dir,
    include_hidden=false,
    include_special=false,
    sort=true,
  )
  // base name -> (generic path, dialect path)
  let picked : Map[String, (String?, String?)] = Map([])
  for file in names {
    if parse_migration_file(file) is Some((base, flavor)) {
      let path = join_path(dir, file)
      let (generic, specific) = picked.get(base).unwrap_or((None, None))
      picked[base] = match flavor {
        Some(d) if d == dialect.suffix() => (generic, Some(path))
        Some(_) => (generic, specific)
        None => (Some(path), specific)
      }
    }
  }
  let bases = picked.keys().collect()
  bases.sort()
  let out : Array[Migration] = []
  for base in bases {
    let (generic, specific) = picked[base]
    let path = match specific {
      Some(path) => Some(path)
      None => generic
    }
    guard path is Some(path) else { continue }
    let sql = @fs.read_file(path).text()
    out.push(Migration::sql(name=base, sql~, use_tx~))
  }
  out
}

///|
/// Read the authoritative schema file for `bootstrap`:
/// `schema.<dialect>.sql` wins over `schema.sql`; `None` when neither
/// exists.
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
/// Classify `file` as `(migration_name, dialect?)`: `0001_x.sql` →
/// `("0001_x", None)`; `0001_x.postgres.sql` → `("0001_x",
/// Some("postgres"))`. Non-`.sql` names return `None`; the reserved
/// `schema[.<dialect>].sql` bootstrap files also return `None`.
fn parse_migration_file(file : String) -> (String, String?)? {
  guard file.has_suffix(".sql") else { return None }
  let stem = file[:file.length() - 4].to_owned()
  for suffix in ["sqlite", "postgres", "mysql"] {
    let tail = ".\{suffix}"
    if stem.has_suffix(tail) {
      let base = stem[:stem.length() - tail.length()].to_owned()
      if base == "schema" {
        return None
      }
      return Some((base, Some(suffix)))
    }
  }
  if stem == "schema" {
    return None
  }
  Some((stem, None))
}

///|
fn join_path(dir : String, file : String) -> String {
  if dir.has_suffix("/") {
    "\{dir}\{file}"
  } else {
    "\{dir}/\{file}"
  }
}
