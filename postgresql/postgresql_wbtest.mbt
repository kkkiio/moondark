///|
test "translate_placeholders rewrites ? to positional parameters" {
  assert_eq(
    translate_placeholders("SELECT * FROM t WHERE a = ? AND b = ?"),
    "SELECT * FROM t WHERE a = $1 AND b = $2",
  )
}

///|
test "translate_placeholders leaves sql without placeholders untouched" {
  assert_eq(
    translate_placeholders("SELECT $1::int4, col FROM t WHERE col = $2"),
    "SELECT $1::int4, col FROM t WHERE col = $2",
  )
}

///|
test "translate_placeholders skips quotes, identifiers and comments" {
  assert_eq(
    translate_placeholders(
      "SELECT 'a?b', \"c?d\" -- e?f\n/* g?h */ FROM t WHERE x = ?",
    ),
    "SELECT 'a?b', \"c?d\" -- e?f\n/* g?h */ FROM t WHERE x = $1",
  )
  // A doubled single quote inside a literal does not end it.
  assert_eq(
    translate_placeholders("SELECT 'it''s ?' WHERE x = ?"),
    "SELECT 'it''s ?' WHERE x = $1",
  )
}

///|
test "translate_placeholders skips dollar-quoted bodies" {
  assert_eq(
    translate_placeholders("SELECT $$a?b$$, $tag$c?d$tag$ WHERE x = ?"),
    "SELECT $$a?b$$, $tag$c?d$tag$ WHERE x = $1",
  )
}

///|
test "translate_placeholders maps ?? to a literal question mark" {
  assert_eq(
    translate_placeholders("SELECT col ?? 'key' AND x = ?"),
    "SELECT col ? 'key' AND x = $1",
  )
}

///|
test "translate_placeholders tolerates unterminated spans" {
  // Left for the server to reject; the rewriter must not loop or panic.
  assert_eq(translate_placeholders("SELECT 'abc"), "SELECT 'abc")
  assert_eq(translate_placeholders("SELECT $tag$x"), "SELECT $tag$x")
  assert_eq(translate_placeholders("SELECT /* x"), "SELECT /* x")
}
