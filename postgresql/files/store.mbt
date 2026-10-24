///|
/// Constructor namespace only — `PostgresFileStore::new` returns a
/// ready `@moondark_files.CasFileStore` whose `FileStore` methods and
/// `routes()` are used directly, so there is no wrapper type here.
type PostgresFileStore

///|
/// Build a `CasFileStore` whose blobs live on disk under `root` and
/// whose key → blob catalog is a `PostgresCatalog` on `db` (the
/// `file_objects` table, see `schema.sql`).
///
/// - `db`：连接池句柄，`file_objects` 表须已由 `schema.sql` 建好。
/// - `key`：签名密钥，泄漏等于可任意伪造上传/下载凭证。
/// - `url_prefix`：`routes()` 挂载的路由前缀，同时是 presigned URL 的前缀。
/// - `default_expires`：`presign_*` 未传 `expires` 时的默认有效期（毫秒）。
/// - `now`：当前 unix 毫秒，测试可注入固定/可变时钟。
pub async fn PostgresFileStore::new(
  db : @moondark_database.DB,
  root~ : String,
  key~ : String,
  url_prefix~ : String = "/_files",
  default_expires~ : Int64 = 3_600_000,
  now~ : () -> Int64 = () => @env.now().reinterpret_as_int64(),
) -> @moondark_files.CasFileStore {
  @moondark_files.CasFileStore::new(
    root~,
    catalog=PostgresCatalog::new(db),
    key~,
    url_prefix~,
    default_expires~,
    now~,
  )
}
