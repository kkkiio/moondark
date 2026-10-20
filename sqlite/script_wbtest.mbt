///|
test "split_script: basic statements" {
  assert_eq(split_script("SELECT 1; SELECT 2"), ["SELECT 1", " SELECT 2"])
  assert_eq(split_script("SELECT 1"), ["SELECT 1"])
  assert_eq(split_script(""), [])
  assert_eq(split_script(" ; ;; "), [])
}

///|
test "split_script: semicolons inside literals and identifiers" {
  assert_eq(split_script("INSERT INTO t VALUES ('a;b', 'c'';d'); SELECT 1"), [
    "INSERT INTO t VALUES ('a;b', 'c'';d')", " SELECT 1",
  ])
  assert_eq(split_script("SELECT \"a;b\" FROM \"t;\"\"t\";SELECT `x;y`"), [
    "SELECT \"a;b\" FROM \"t;\"\"t\"", "SELECT `x;y`",
  ])
  assert_eq(split_script("SELECT [a;b] FROM t; SELECT 2"), [
    "SELECT [a;b] FROM t", " SELECT 2",
  ])
  // SQLite strings have no backslash escape: `'a\'` is complete.
  assert_eq(split_script("SELECT 'a\\'; SELECT 2"), [
    "SELECT 'a\\'", " SELECT 2",
  ])
}

///|
test "split_script: comments do not split, but are kept in the chunk" {
  assert_eq(
    split_script("-- hello; world\nSELECT 1; /* block ; comment */ SELECT 2"),
    ["-- hello; world\nSELECT 1", " /* block ; comment */ SELECT 2"],
  )
  // block comments do not nest: the first `*/` closes it
  assert_eq(split_script("/* a /* b */ SELECT 1; SELECT 2"), [
    "/* a /* b */ SELECT 1", " SELECT 2",
  ])
  // comment-only chunks are dropped
  assert_eq(split_script("SELECT 1; -- trailing; comment\n/* x; */"), [
    "SELECT 1",
  ])
}

///|
test "split_script: trigger bodies stay whole" {
  let trigger = "CREATE TRIGGER log AFTER INSERT ON a BEGIN INSERT INTO b VALUES (1); UPDATE c SET x = CASE WHEN 1 THEN 2 END; END"
  assert_eq(split_script(trigger + "; SELECT 1"), [trigger, " SELECT 1"])
  let temp = "create temp trigger t before delete on a begin select 1; end"
  assert_eq(split_script(temp + ";select 2;"), [temp, "select 2"])
  // only CREATE … TRIGGER enters trigger mode
  assert_eq(
    split_script(
      "CREATE TABLE trigger_log(x); CREATE TEMP TABLE t(y); SELECT 1",
    ),
    ["CREATE TABLE trigger_log(x)", " CREATE TEMP TABLE t(y)", " SELECT 1"],
  )
  // an unterminated trigger is returned as one chunk
  assert_eq(
    split_script("CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1;"),
    ["CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1;"],
  )
}
