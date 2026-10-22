///|
/// 逻辑 key 到物理 blob 的指针记录，随 `Catalog::upsert` 单行提交。
/// `hash` 是内容寻址的 sha256 hex（blob 落盘路径由它导出）；
/// `size`/`content_type` 与指针同生共死，下载不再需要独立 meta 存储。
pub(all) struct CatalogEntry {
  hash : String
  size : Int64
  content_type : String?
}

///|
/// 键到 blob 的目录，是 CAS 提交语义的载体：blob 字节完整落盘后，
/// `upsert` 单行翻转指针即完成一次原子提交——实现方必须保证单个
/// `key` 的 `upsert` 原子生效（DB 单行 upsert、内存单键赋值都天然满足）。
/// `remove` 只摘指针，不回收 blob：覆盖/删除产生的孤儿 blob 留给
/// 未来的 mark-sweep GC 统一清理。
pub(open) trait Catalog {
  /// 建立/覆盖 `key` 到 `entry` 的映射。
  async fn upsert(Self, key~ : String, entry~ : CatalogEntry) -> Unit
  /// 查询 `key` 当前指向的 blob；未登记返回 `None`。
  async fn lookup(Self, key~ : String) -> CatalogEntry?
  /// 摘除 `key` 的映射；key 不存在时是 no-op。
  async fn remove(Self, key~ : String) -> Unit
}

///|
/// 进程内 `Catalog`：一张 `Map`。无持久化，适合测试、开发与
/// "重启即清空"的场景；生产环境用各集成模块的 DB 实现。
pub struct MemoryCatalog {
  entries : Map[String, CatalogEntry]
}

///|
pub fn MemoryCatalog::new() -> MemoryCatalog {
  { entries: {}, }
}

///|
pub impl Catalog for MemoryCatalog with fn upsert(self, key~, entry~) -> Unit raise {
  self.entries[key] = entry
}

///|
pub impl Catalog for MemoryCatalog with fn lookup(self, key~) -> CatalogEntry? raise {
  self.entries.get(key)
}

///|
pub impl Catalog for MemoryCatalog with fn remove(self, key~) -> Unit raise {
  self.entries.remove(key)
}

///|
pub extend MemoryCatalog with Catalog::{upsert, lookup, remove}
