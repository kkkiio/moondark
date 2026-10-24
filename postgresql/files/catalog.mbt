///|
/// `@moondark_files.Catalog` backed by a PostgreSQL table — one row per
/// stored object, mapping `key` to the `CatalogEntry` (hash, size,
/// content_type) of its CAS blob, written in PostgreSQL's native SQL
/// (`$N` placeholders). The blob bytes themselves live on disk under
/// the `CasFileStore` root; this table is only the key → blob index.
struct PostgresCatalog {
  db : @moondark_database.DB
  table : String
}

///|
/// `table` is the name of the catalog table, see `schema.sql` for its
/// schema. It is interpolated verbatim and must be a trusted SQL identifier.
pub fn PostgresCatalog::new(
  db : @moondark_database.DB,
  table~ : String = "file_objects",
) -> PostgresCatalog {
  PostgresCatalog::{ db, table, }
}

///|
/// Insert or replace the catalog row of `key` in one statement:
/// `INSERT ... ON CONFLICT(key) DO UPDATE`,
/// so a re-`put` atomically retargets the key at its new blob.
pub impl @moondark_files.Catalog for PostgresCatalog with fn upsert(
  self,
  key~,
  entry~,
) {
  ignore(
    self.db.execute(
      "INSERT INTO \{self.table} (key, hash, size, content_type) VALUES ($1, $2, $3, $4) ON CONFLICT(key) DO UPDATE SET hash = excluded.hash, size = excluded.size, content_type = excluded.content_type",
      params=[key, entry.hash, entry.size, entry.content_type],
    ),
  )
}

///|
/// Fetch the catalog row of `key`, or `None` when the key has no
/// object.
pub impl @moondark_files.Catalog for PostgresCatalog with fn lookup(self, key~) {
  let rows = self.db.query_opt(
    "SELECT hash, size, content_type FROM \{self.table} WHERE key = $1",
    params=[key],
  )

  guard rows is Some(row) else { return None }
  let hash = (row.get_name("hash") : String)
  let size = (row.get_name("size") : Int64)
  let content_type = (row.get_name("content_type") : String?)
  Some(@moondark_files.CatalogEntry::{ hash, size, content_type, })
}

///|
/// Drop the catalog row of `key`; a missing key is a no-op.
pub impl @moondark_files.Catalog for PostgresCatalog with fn remove(self, key~) {
  ignore(
    self.db.execute("DELETE FROM \{self.table} WHERE key = $1", params=[key]),
  )
}

///|
pub extend PostgresCatalog with @moondark_files.Catalog::{
  upsert,
  lookup,
  remove,
}
