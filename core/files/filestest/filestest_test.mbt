///|
async test "local file store passes the conformance suite" {
  let root = @fs.tmpdir(prefix="moondark-filestest")
  let store = @files.LocalFileStore(root~, key="filestest-secret")
  @filestest.check_file_store(store)
}
