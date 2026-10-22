///|
/// Conformance suite for `@files.FileStore` backends. Every backend's
/// tests call it with a ready store (e.g. an empty bucket or a fresh
/// root dir). It only touches the `filestest-k1.txt` key and deletes
/// it before and after, so other keys are left alone.
///
/// Presign 部分只做后端无关的形状断言（URL 非空、方法是 PUT）：
/// presigned URL 能否真的完成上传/下载由各后端自己的集成测试验证，
/// 本地后端见 `files` 包的端到端测试。
pub async fn check_file_store(store : &@files.FileStore) -> Unit {
  let key = "filestest-k1.txt"
  store.delete(key~)
  // Deleting a missing key is a no-op.
  store.delete(key~)
  assert_false(store.exists(key~))
  try {
    ignore(store.get(key~))
    fail("get on a missing key should raise NotFound")
  } catch {
    @files.NotFound(_) => ()
    e => raise e
  }
  store.put(key~, "hello moondark", content_type="text/plain")
  assert_true(store.exists(key~))
  assert_eq(store.get(key~).binary(), b"hello moondark")
  // `put` on an existing key overwrites.
  store.put(key~, "v2")
  assert_eq(store.get(key~).binary(), b"v2")
  // Nested keys are part of the contract (dirent-style layout).
  let nested = "dir/sub/filestest-k2.bin"
  store.delete(key=nested)
  store.put(key=nested, b"\x00\x01\x02")
  assert_eq(store.get(key=nested).binary(), b"\x00\x01\x02")
  store.delete(key=nested)
  assert_false(store.exists(key=nested))
  // Slash-prefix keys are independent objects: creating `dir/x` must
  // not make `dir` exist, and both can coexist in either order.
  let parent = "filestest-dir"
  let child = "filestest-dir/filestest-k3.txt"
  store.delete(key=parent)
  store.delete(key=child)
  store.put(key=child, "c")
  assert_false(store.exists(key=parent))
  store.put(key=parent, "p")
  assert_eq(store.get(key=parent).binary(), b"p")
  assert_eq(store.get(key=child).binary(), b"c")
  store.delete(key=parent)
  assert_eq(store.get(key=child).binary(), b"c")
  store.delete(key=child)
  // presign_put / presign_get shape checks (backend-agnostic).
  let upload = store.presign_put(
    key~,
    content_type="text/plain",
    max_size=1024L,
  )
  assert_eq(upload.meth, @http.RequestMethod::Put)
  assert_true(!upload.url.is_empty())
  let url = store.presign_get(key~, download_name="report.txt")
  assert_true(!url.is_empty())
  store.delete(key~)
  assert_false(store.exists(key~))
}
