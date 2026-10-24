///|
fn[T : ToSql + FromSql + Eq + Debug] round_trip(value : T) -> Unit raise {
  assert_eq((FromSql::from_sql(ToSql::to_sql(value)) : T), value)
}

///|
test "scalar codecs preserve values and nullable parameters" {
  round_trip(true)
  round_trip(false)
  round_trip(-2147483648)
  round_trip(2147483647)
  round_trip(-9223372036854775808L)
  round_trip(9223372036854775807L)
  round_trip(4294967295U)
  round_trip(18446744073709551615UL)
  round_trip(1.25F)
  round_trip(1.25)
  round_trip("hello")
  round_trip(b"\x00\xff")
  let timestamp = @time.ZonedDateTime::from_unix_second(123L)
  let decoded : @time.ZonedDateTime = FromSql::from_sql(
    ToSql::to_sql(timestamp),
  )
  assert_eq(decoded.to_unix_second(), timestamp.to_unix_second())
  round_trip(({ "key": [1, true, null] } : Json))
  round_trip((Some("value") : String?))
  round_trip((None : String?))
  let text = "hello"
  let bytes = b"abcd"
  assert_true(ToSql::to_sql(text[1:4]) is String("ell"))
  assert_true(ToSql::to_sql(bytes[1:3]) is Bytes(b"bc"))
  assert_true(ToSql::to_sql(Value::Null) is Null)
  assert_true((FromSql::from_sql(Value::Null) : Value) is Null)
}

///|
fn[T : FromSql] expect_decode(value : Value, _type : T?) -> Unit raise {
  try ignore(T::from_sql(value)) catch {
    DatabaseError::Decode(..) => ()
    e => raise e
  } noraise {
    _ => fail("expected Decode")
  }
}

///|
test "numeric overflow, invalid nulls and malformed JSON report Decode" {
  expect_decode(Int64(2147483648L), (None : Int32?))
  expect_decode(Int64(-2147483649L), (None : Int32?))
  expect_decode(Int64(-1), (None : UInt32?))
  expect_decode(Int64(4294967296L), (None : UInt32?))
  expect_decode(Int64(-1), (None : UInt64?))
  expect_decode(String("18446744073709551616"), (None : UInt64?))
  expect_decode(Double(1.0e40), (None : Float?))
  expect_decode(Null, (None : String?))
  expect_decode(Int64(2), (None : Bool?))
  expect_decode(String("{"), (None : Json?))
  assert_eq((FromSql::from_sql(Int64(0)) : Bool), false)
  assert_eq((FromSql::from_sql(Int64(1)) : Bool), true)
  assert_eq((FromSql::from_sql(Int64(42)) : Double), 42.0)
  assert_eq((FromSql::from_sql(Int64(42)) : Float), 42.0F)
}

///|
test "row lookup distinguishes missing columns from SQL null" {
  let row = Row::{
    names: ["value", "value", "null"],
    data: [Int64(42), Int64(99), Null],
  }
  assert_eq((row.get_name("value") : Int32), 42)
  assert_eq((row.get(1) : Int64), 99)
  assert_eq((row.try_get(2) : String?), None)
  assert_eq((row.try_get_name("null") : Int64?), None)
  for name in ["missing", "VALUE"] {
    try ignore((row.get_name(name) : String?)) catch {
      DatabaseError::ColumnNotFound(actual) => assert_eq(actual, name)
      e => raise e
    } noraise {
      _ => fail("expected ColumnNotFound")
    }
  }
  for index in [-1, 3] {
    try ignore((row.get(index) : String?)) catch {
      DatabaseError::ColumnNotFound(_) => ()
      e => raise e
    } noraise {
      _ => fail("expected ColumnNotFound")
    }
  }
}
