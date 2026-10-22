///|
/// The app folds every integration package's `schema.sql` into its
/// own version packages; keep `v0002_moondark_sessions/up.sql` (and
/// the bootstrap snapshot) in sync with
/// `xziheng/moondark_sqlite/sessions`'s DDL — comments and whitespace
/// are ignored, statements must match.
async test "sessions migration mirrors the package's schema.sql" {
  let packaged = sql_norm(
    @fs.read_file("../../sqlite/sessions/schema.sql").text(),
  )
  assert_eq(
    sql_norm(@fs.read_file("migrations/v0002_moondark_sessions/up.sql").text()),
    packaged,
  )
  assert_true(
    sql_norm(@fs.read_file("migrations/schema.sql").text()).contains(packaged),
  )
}

///|
/// Strip `--` comment lines and join the remaining lines so two files
/// with the same statements compare equal.
fn sql_norm(sql : String) -> String {
  let lines : Array[String] = []
  for line in sql.split("\n") {
    let line = line.trim()
    if line.length() > 0 && !line.has_prefix("--") {
      lines.push(line.to_owned())
    }
  }
  lines.join(" ")
}
