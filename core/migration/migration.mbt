///|
/// Offline, in-place schema migrations.
///
/// Migrations are hand-written, linearly ordered by name (the
/// convention is a zero-padded prefix: `0001_init`, `0002_users`).
/// Applying a migration is bookkeeping in two tables: the applied set
/// `moondark_migrations` and an append-only attempt log
/// `moondark_migration_records` whose `started` rows expose runs that
/// crashed mid-migration. DDL is applied in place through
/// `Conn::batch_execute`; `use_tx` wraps the body plus the applied-set
/// row in `BEGIN`/`COMMIT` on drivers with transactional DDL.
///
/// Typical startup wiring:
///
/// ```moonbit nocheck
/// db.with_conn(conn => {
///   let migrator = @migration.Migrator::new(conn~, dialect=Sqlite)
///   ignore(migrator.up(migrations))
/// })
/// ```

///|
/// One named migration, ordered lexicographically by `name`.
///
/// `Sql` carries a script executed via `Conn::batch_execute`; `Run`
/// carries arbitrary MoonBit code for data migrations that plain SQL
/// cannot express (the callback receives the migrator's connection).
/// `use_tx` (default `true`) brackets the body and the bookkeeping
/// insert in `BEGIN`/`COMMIT`; set it `false` for statements that
/// cannot run inside a transaction.
pub(all) enum Migration {
  Sql(name~ : String, sql~ : String, use_tx~ : Bool)
  Run(name~ : String, use_tx~ : Bool, run~ : async (@database.Conn) -> Unit)
}

///|
pub fn Migration::sql(
  name~ : String,
  sql~ : String,
  use_tx~ : Bool = true,
) -> Migration {
  Sql(name~, sql~, use_tx~)
}

///|
pub fn Migration::run(
  name~ : String,
  run~ : async (@database.Conn) -> Unit,
  use_tx~ : Bool = true,
) -> Migration {
  Run(name~, use_tx~, run~)
}

///|
pub fn Migration::name(self : Migration) -> String {
  match self {
    Sql(name~, ..) | Run(name~, ..) => name
  }
}

///|
fn Migration::use_tx(self : Migration) -> Bool {
  match self {
    Sql(use_tx~, ..) | Run(use_tx~, ..) => use_tx
  }
}

///|
/// Content fingerprint stored in `moondark_migrations` and compared on
/// later runs to detect an applied migration that was edited. `Run`
/// migrations carry no script to fingerprint.
fn Migration::checksum(self : Migration) -> String {
  match self {
    Sql(sql~, ..) => fnv1a64(sql)
    Run(..) => ""
  }
}

///|
/// Database flavor. Determines the bookkeeping DDL and which
/// `schema.<dialect>.sql` / `NNNN_x.<dialect>.sql` file overrides
/// apply in `load_schema`/`Migration::load_dir`.
pub(all) enum Dialect {
  Sqlite
  Postgres
  Mysql
}

///|
/// File-name suffix matching this dialect, e.g. `schema.postgres.sql`.
pub fn Dialect::suffix(self : Dialect) -> String {
  match self {
    Sqlite => "sqlite"
    Postgres => "postgres"
    Mysql => "mysql"
  }
}

///|
/// Errors from migration planning and application. Connection-level
/// failures still surface as plain `Error`; these cover the states the
/// operator has to distinguish.
pub suberror MigrationError {
  /// A `started` record with no terminal status means a previous run
  /// crashed mid-migration — the database is in an unknown state.
  /// Carries the affected migration names.
  DirtyState(Array[String])
  /// An applied migration's script changed on disk since it ran.
  ChecksumMismatch(name~ : String, stored~ : String, current~ : String)
  /// A pending migration sorts at or before the newest applied one —
  /// the migration list is append-only at the tail.
  OutOfOrder(name~ : String, latest~ : String)
  /// Applying `name` failed; details are in the records table.
  ApplyFailed(name~ : String, Error)
  /// `bootstrap` only runs on an empty applied set.
  NotFresh
  /// Bad migration or table name.
  InvalidName(String)
}

///|
/// `ApplyFailed` carries the underlying error; every other payload is
/// a name/checksum — all safe to print.
pub impl Show for MigrationError with fn to_string(self) {
  match self {
    DirtyState(names) => {
      let joined = names.join(", ")
      "DirtyState(\{joined})"
    }
    ChecksumMismatch(name~, stored~, current~) =>
      "ChecksumMismatch(name=\{name}, stored=\{stored}, current=\{current})"
    OutOfOrder(name~, latest~) => "OutOfOrder(name=\{name}, latest=\{latest})"
    ApplyFailed(name~, e) => "ApplyFailed(\{name}, \{e})"
    NotFresh => "NotFresh"
    InvalidName(name) => "InvalidName(\{name})"
  }
}

///|
pub extend MigrationError with Show::{to_string, output}

///|
/// Runs pending migrations against `conn` and keeps the bookkeeping
/// tables. Holds the connection for the whole migration run — check it
/// from `db.with_conn(conn => ...)` and use the migrator inside that callback.
pub struct Migrator {
  conn : @database.Conn
  dialect : Dialect
  migrations_table : String
  records_table : String
}

///|
/// Create a migrator over `conn`. The bookkeeping tables default to
/// `moondark_migrations`/`moondark_migration_records`; override them
/// only when sharing a database with another tool's tables.
pub fn Migrator::new(
  conn~ : @database.Conn,
  dialect~ : Dialect,
  migrations_table~ : String = "moondark_migrations",
  records_table~ : String = "moondark_migration_records",
) -> Migrator raise {
  for t in [migrations_table, records_table] {
    if !is_ident(t) {
      raise InvalidName(t)
    }
  }
  Migrator::{ conn, dialect, migrations_table, records_table, }
}

///|
/// Create the bookkeeping tables if they do not exist yet. The DDL
/// lives in `bookkeeping.<dialect>.sql` (embedded at build time via
/// `dev_build`); `{migrations_table}`/`{records_table}` placeholders
/// are substituted with the configured names.
pub async fn Migrator::ensure_tables(self : Migrator) -> Unit {
  let ddl = match self.dialect {
    Sqlite => bookkeeping_sqlite
    Postgres => bookkeeping_postgres
    Mysql => bookkeeping_mysql
  }
  self.conn.batch_execute(
    ddl
    .replace_all(old="{migrations_table}", new=self.migrations_table)
    .replace_all(old="{records_table}", new=self.records_table),
  )
}

///|
/// Apply every pending migration in name order; returns the names
/// applied during this call. Refuses to run while an unfinished
/// (`started`) record exists — a previous run crashed mid-migration
/// and the database state is unknown (`DirtyState`). Migrations are
/// skipped when already applied; an applied migration whose script
/// changed on disk fails `ChecksumMismatch` before anything runs.
/// History is append-only: a pending migration that does not sort
/// after the newest applied name fails `OutOfOrder`.
pub async fn Migrator::up(
  self : Migrator,
  migrations : ArrayView[Migration],
) -> Array[String] {
  self.ensure_tables()
  self.check_dirty()
  self.check_drift(migrations)
  let pending = self.pending(migrations)
  if pending is [first, ..] {
    self.check_tail_order(first.name())
  }
  let applied : Array[String] = []
  for mig in pending {
    self.apply(mig)
    applied.push(mig.name())
  }
  applied
}

///|
/// Migrations not yet applied, in name order. Names must be unique
/// and match `[0-9A-Za-z_][0-9A-Za-z_.-]*`.
pub async fn Migrator::pending(
  self : Migrator,
  migrations : ArrayView[Migration],
) -> Array[Migration] {
  self.ensure_tables()
  let sorted = validate(migrations)
  let applied = self.applied_set()
  sorted.filter(fn(mig) { !applied.contains(mig.name()) })
}

///|
/// Per-migration status over the union of `migrations` and the applied
/// set, ordered by name: `applied`/`applied_at` from the set,
/// `drifted` when the stored checksum no longer matches, and
/// `last_status` from the newest record row for that migration.
pub async fn Migrator::status(
  self : Migrator,
  migrations : ArrayView[Migration],
) -> Array[MigrationStatus] {
  self.ensure_tables()
  let sorted = validate(migrations)
  let applied = self.applied_set()
  let last = self.last_status()
  let out : Array[MigrationStatus] = []
  for mig in sorted {
    let name = mig.name()
    match applied.get(name) {
      Some((checksum, at)) =>
        out.push({
          name,
          applied: true,
          applied_at: Some(at),
          drifted: mig.checksum() != "" && checksum != mig.checksum(),
          last_status: last.get(name).bind(RecordStatus::of_str),
        })
      None =>
        out.push({
          name,
          applied: false,
          applied_at: None,
          drifted: false,
          last_status: last.get(name).bind(RecordStatus::of_str),
        })
    }
  }
  // Rows applied by earlier versions whose migration is no longer
  // offered still belong in the report.
  for name, entry in applied {
    if sorted.iter().all(fn(mig) { mig.name() != name }) {
      out.push({
        name,
        applied: true,
        applied_at: Some(entry.1),
        drifted: false,
        last_status: last.get(name).bind(RecordStatus::of_str),
      })
    }
  }
  out.sort_by(fn(a, b) { a.name.lexical_compare(b.name) })
  out
}

///|
/// Bootstrap a fresh database from the authoritative `schema.sql`:
/// runs the script, then records every offered migration as applied
/// so incremental `up` starts from here. Refuses `NotFresh` when the
/// applied set is non-empty — `bootstrap` is not a repair path.
pub async fn Migrator::bootstrap(
  self : Migrator,
  schema~ : String,
  migrations~ : ArrayView[Migration],
  use_tx~ : Bool = true,
) -> Unit {
  self.ensure_tables()
  if !self.applied_set().is_empty() {
    raise NotFresh
  }
  self.check_dirty()
  let sorted = validate(migrations)
  let started_ms = now_ms()
  let rec_id = self.insert_started("bootstrap")
  let result : Result[Unit, Error] = Ok(
    {
      if use_tx {
        ignore(self.conn.execute("BEGIN"))
      }
      self.conn.batch_execute(schema)
      let ts = now_ms()
      for mig in sorted {
        self.insert_applied(mig.name(), mig.checksum(), ts)
      }
      if use_tx {
        ignore(self.conn.execute("COMMIT"))
      }
    },
  ) catch {
    e => Err(e)
  }
  match result {
    Ok(_) => self.finish_record(rec_id, "done", "", started_ms)
    Err(e) => {
      if use_tx {
        ignore(self.conn.execute("ROLLBACK")) catch {
          re =>
            @xlog.warn(category="moondark.migration") <?
              {
                "error": re.to_string(),
                "migration": "bootstrap",
                "message": "ROLLBACK failed",
              }
        }
      }
      self.finish_record(rec_id, "failed", e.to_string(), started_ms) catch {
        fe =>
          @xlog.warn(category="moondark.migration") <?
            {
              "error": fe.to_string(),
              "migration": "bootstrap",
              "message": "records write failed",
            }
      }
      raise e
    }
  }
}

///|
/// Apply a single migration: log `started`, run the body (inside
/// `BEGIN`/`COMMIT` when `use_tx`), insert the applied-set row, log
/// `done`/`failed`. The record update happens outside the migration
/// transaction so failures survive the rollback.
async fn Migrator::apply(self : Migrator, mig : Migration) -> Unit {
  let name = mig.name()
  let started_ms = now_ms()
  let rec_id = self.insert_started(name)
  let result : Result[Unit, Error] = Ok(
    {
      if mig.use_tx() {
        ignore(self.conn.execute("BEGIN"))
      }
      match mig {
        Sql(sql~, ..) => self.conn.batch_execute(sql)
        Run(run~, ..) => run(self.conn)
      }
      self.insert_applied(name, mig.checksum(), now_ms())
      if mig.use_tx() {
        ignore(self.conn.execute("COMMIT"))
      }
    },
  ) catch {
    e => Err(e)
  }
  match result {
    Ok(_) => self.finish_record(rec_id, "done", "", started_ms)
    Err(e) => {
      if mig.use_tx() {
        ignore(self.conn.execute("ROLLBACK")) catch {
          re =>
            @xlog.warn(category="moondark.migration") <?
              {
                "error": re.to_string(),
                "migration": name,
                "message": "ROLLBACK failed",
              }
        }
      }
      self.finish_record(rec_id, "failed", e.to_string(), started_ms) catch {
        fe =>
          @xlog.warn(category="moondark.migration") <?
            {
              "error": fe.to_string(),
              "migration": name,
              "message": "records write failed",
            }
      }
      raise ApplyFailed(name~, e)
    }
  }
}

///|
/// Outcome of a single attempt recorded in the records table.
pub(all) enum RecordStatus {
  Started
  Done
  Failed
}

///|
fn RecordStatus::of_str(s : String) -> RecordStatus? {
  match s {
    "started" => Some(Started)
    "done" => Some(Done)
    "failed" => Some(Failed)
    _ => None
  }
}

///|
/// Report line produced by `Migrator::status`.
pub(all) struct MigrationStatus {
  name : String
  applied : Bool
  applied_at : Int64?
  drifted : Bool
  last_status : RecordStatus?
}

///|
/// Sort by name, validating the charset and rejecting duplicates.
fn validate(migrations : ArrayView[Migration]) -> Array[Migration] raise {
  let sorted = migrations.to_owned()
  sorted.sort_by(fn(a, b) { a.name().lexical_compare(b.name()) })
  let mut prev = ""
  for mig in sorted {
    if !is_migration_name(mig.name()) {
      raise InvalidName(mig.name())
    }
    if mig.name() == prev {
      raise InvalidName("duplicate migration \{mig.name()}")
    }
    prev = mig.name()
  }
  sorted
}

///|
/// Raise `OutOfOrder` when the first pending name does not sort after
/// the newest applied name — the rest of the pending list is already
/// sorted, so checking the head covers all of them.
async fn Migrator::check_tail_order(
  self : Migrator,
  first_pending : String,
) -> Unit {
  let applied = self.applied_set()
  let mut latest = ""
  for name, _ in applied {
    if name.lexical_compare(latest) > 0 {
      latest = name
    }
  }
  if !applied.is_empty() && first_pending.lexical_compare(latest) <= 0 {
    raise OutOfOrder(name=first_pending, latest~)
  }
}

///|
/// Raise `DirtyState` while unfinished (`started`) records exist.
async fn Migrator::check_dirty(self : Migrator) -> Unit {
  let stale = self.unfinished()
  if !stale.is_empty() {
    raise DirtyState(stale)
  }
}

///|
/// Raise `ChecksumMismatch` when an applied migration's stored
/// checksum differs from the script now on disk.
async fn Migrator::check_drift(
  self : Migrator,
  migrations : ArrayView[Migration],
) -> Unit {
  let applied = self.applied_set()
  for mig in migrations {
    let name = mig.name()
    if applied.get(name) is Some((stored, _)) &&
      mig.checksum() != "" &&
      stored != mig.checksum() {
      raise ChecksumMismatch(name~, stored~, current=mig.checksum())
    }
  }
}

///|
/// `[0-9A-Za-z_][0-9A-Za-z_.-]*` — file-stem shaped names.
fn is_migration_name(name : String) -> Bool {
  is_name(name) && name[0] != '.'
}

///|
/// `[A-Za-z_][A-Za-z0-9_]*` — unquoted SQL identifiers.
fn is_ident(name : String) -> Bool {
  is_name(name) && !(name[0] >= '0' && name[0] <= '9')
}

///|
fn is_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  for c in name {
    if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_' ||
      c == '.' ||
      c == '-' {
      continue
    }
    return false
  }
  true
}

///|
/// FNV-1a 64-bit fingerprint of the script text, decimal string.
fn fnv1a64(s : String) -> String {
  let mut h : UInt64 = 14695981039346656037
  for b in @utf8.encode(s) {
    h = (h ^ b.to_int().to_uint64()) * 1099511628211
  }
  h.reinterpret_as_int64().to_string()
}

///|
fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}
