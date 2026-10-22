///|
/// `@moondark_files.Catalog` backed by a SQLite table — one row per
/// stored object, mapping `key` to the `CatalogEntry` (hash, size,
/// content_type) of its CAS blob, written in SQLite's native SQL
/// (`?` placeholders). The blob bytes themselves live on disk under
/// the `CasFileStore` root; this table is only the key → blob index.
struct SqliteCatalog {
  db : @sql.DB
  table : String
}

///|
/// `table` is the name of the catalog table, see `schema.sql` for its
/// schema (including the recommended `busy_timeout` pragma). It is
/// interpolated into SQL statements verbatim, so it must be a trusted
/// identifier.
pub fn SqliteCatalog::new(
  db : @sql.DB,
  table~ : String = "file_objects",
) -> SqliteCatalog {
  SqliteCatalog::{ db, table, }
}

///|
/// Insert or replace the catalog row of `key` in one statement:
/// `INSERT ... ON CONFLICT(key) DO UPDATE` (the SQLite 3.24+ upsert),
/// so a re-`put` atomically retargets the key at its new blob.
pub impl @moondark_files.Catalog for SqliteCatalog with fn upsert(
  self,
  key~,
  entry~,
) {
  ignore(
    self.db.execute(
      "INSERT INTO \{self.table} (key, hash, size, content_type) VALUES (?, ?, ?, ?) ON CONFLICT(key) DO UPDATE SET hash = excluded.hash, size = excluded.size, content_type = excluded.content_type",
      params=[key, entry.hash, entry.size, opt_text(entry.content_type)],
    ),
  )
}

///|
/// Fetch the catalog row of `key`, or `None` when the key has no
/// object.
pub impl @moondark_files.Catalog for SqliteCatalog with fn lookup(self, key~) {
  let rows = self.db.query(
    "SELECT hash, size, content_type FROM \{self.table} WHERE key = ?",
    params=[key],
  )
  defer rows.close()
  guard rows.next() is Some(row) else { return None }
  let hash = match row.get("hash") {
    Some(@driver.Value::String(s)) => s
    _ => fail("files: malformed hash column")
  }
  let size = match row.get("size") {
    Some(@driver.Value::Int64(v)) => v
    _ => fail("files: malformed size column")
  }
  let content_type = match row.get("content_type") {
    Some(@driver.Value::String(s)) => Some(s)
    Some(@driver.Value::Null) => None
    _ => fail("files: malformed content_type column")
  }
  Some(@moondark_files.CatalogEntry::{ hash, size, content_type, })
}

///|
/// Drop the catalog row of `key`; a missing key is a no-op.
pub impl @moondark_files.Catalog for SqliteCatalog with fn remove(self, key~) {
  ignore(
    self.db.execute("DELETE FROM \{self.table} WHERE key = ?", params=[key]),
  )
}

///|
pub extend SqliteCatalog with @moondark_files.Catalog::{upsert, lookup, remove}

///|
/// `NULL` or the text, for the nullable `content_type` column.
fn opt_text(value : String?) -> @driver.Value {
  match value {
    Some(v) => @driver.Value::String(v)
    None => @driver.Value::Null
  }
}
