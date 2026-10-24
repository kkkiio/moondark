///|
struct Row {
  names : Array[String]
  data : Array[Value]
}

///|
/// Read-only view of the row's column names.
pub fn Row::columns(self : Row) -> ArrayView[String] {
  self.names[:]
}

///|
/// Read-only view of the row's raw driver values.
pub fn Row::values(self : Row) -> ArrayView[Value] {
  self.data[:]
}

///|
/// Number of columns in the row.
pub fn Row::len(self : Row) -> Int32 {
  self.data.length()
}

///|
/// Zero-based index of the first column named `name`, or `None` if absent.
pub fn Row::index_of(self : Row, name : String) -> Int32? {
  for i, column in self.names {
    if column == name {
      return Some(i)
    }
  }
  None
}

///|
/// Decode the column at `index` into `T` (use `T?` for nullable columns).
pub fn[T : FromSql] Row::get(self : Row, index : Int32) -> T raise {
  if index < 0 || index >= self.data.length() {
    raise DatabaseError::ColumnNotFound(index.to_string())
  }
  T::from_sql(self.data[index])
}

///|
/// Decode the column named `name` into `T`; raises `DatabaseError::ColumnNotFound` if `name` is absent.
pub fn[T : FromSql] Row::get_name(self : Row, name : String) -> T raise {
  match self.index_of(name) {
    Some(index) => self.get(index)
    None => raise DatabaseError::ColumnNotFound(name)
  }
}

///|
/// Decode the column at `index` into `T?`, returning `None` when the SQL value is `NULL`.
pub fn[T : FromSql] Row::try_get(self : Row, index : Int32) -> T? raise {
  self.get(index)
}

///|
/// Decode the column named `name` into `T?`, returning `None` when the SQL value is `NULL`.
pub fn[T : FromSql] Row::try_get_name(self : Row, name : String) -> T? raise {
  self.get_name(name)
}

///|
pub impl ToSql for Value with fn to_sql(self) {
  self
}

///|
pub impl ToSql for Bool with fn to_sql(self) {
  Value::Bool(self)
}

///|
pub impl ToSql for Int32 with fn to_sql(self) {
  Value::Int64(self.to_int64())
}

///|
pub impl ToSql for Int64 with fn to_sql(self) {
  Value::Int64(self)
}

///|
pub impl ToSql for UInt32 with fn to_sql(self) {
  Value::Int64(self.to_int64())
}

///|
pub impl ToSql for UInt64 with fn to_sql(self) {
  if self <= 9223372036854775807UL {
    Value::Int64(self.reinterpret_as_int64())
  } else {
    Value::String(self.to_string())
  }
}

///|
pub impl ToSql for Float with fn to_sql(self) {
  Value::Double(self.to_double())
}

///|
pub impl ToSql for Double with fn to_sql(self) {
  Value::Double(self)
}

///|
pub impl ToSql for String with fn to_sql(self) {
  Value::String(self)
}

///|
pub impl ToSql for StringView with fn to_sql(self) {
  Value::String(self.to_owned())
}

///|
pub impl ToSql for Bytes with fn to_sql(self) {
  Value::Bytes(self)
}

///|
pub impl ToSql for BytesView with fn to_sql(self) {
  Value::Bytes(self.to_owned())
}

///|
pub impl ToSql for @time.ZonedDateTime with fn to_sql(self) {
  Value::Timestamp(self)
}

///|
pub impl ToSql for Json with fn to_sql(self) {
  Value::String(self.stringify())
}

///|
pub impl[T : ToSql] ToSql for T? with fn to_sql(self) {
  match self {
    Some(value) => value.to_sql()
    None => Value::Null
  }
}

///|
pub impl FromSql for Value with fn from_sql(value) {
  match value {
    value => value
  }
}

///|
pub impl FromSql for Bool with fn from_sql(value) {
  match value {
    Bool(v) => v
    Int64(0) => false
    Int64(1) => true
    _ => raise DatabaseError::Decode(expected="Bool", actual=value)
  }
}

///|
pub impl FromSql for Int32 with fn from_sql(value) {
  match value {
    Int64(v) if v >= -2147483648L && v <= 2147483647L => v.to_int()
    _ => raise DatabaseError::Decode(expected="Int32", actual=value)
  }
}

///|
pub impl FromSql for Int64 with fn from_sql(value) {
  match value {
    Int64(v) => v
    _ => raise DatabaseError::Decode(expected="Int64", actual=value)
  }
}

///|
pub impl FromSql for UInt32 with fn from_sql(value) {
  match value {
    Int64(v) if v >= 0 && v <= 4294967295L => v.to_int().reinterpret_as_uint()
    _ => raise DatabaseError::Decode(expected="UInt32", actual=value)
  }
}

///|
pub impl FromSql for UInt64 with fn from_sql(value) {
  match value {
    Int64(v) if v >= 0 => v.reinterpret_as_uint64()
    String(v) =>
      @string.parse_uint64(v) catch {
        _ => raise DatabaseError::Decode(expected="UInt64", actual=value)
      }
    _ => raise DatabaseError::Decode(expected="UInt64", actual=value)
  }
}

///|
pub impl FromSql for Float with fn from_sql(value) {
  match value {
    Double(v) if v.is_nan() ||
      v.is_inf() ||
      (v >= -3.4028234663852886e38 && v <= 3.4028234663852886e38) =>
      Float::from_double(v)
    Int64(v) => Float::from_int64(v)
    _ => raise DatabaseError::Decode(expected="Float", actual=value)
  }
}

///|
pub impl FromSql for Double with fn from_sql(value) {
  match value {
    Double(v) => v
    Int64(v) => v.to_double()
    _ => raise DatabaseError::Decode(expected="Double", actual=value)
  }
}

///|
pub impl FromSql for String with fn from_sql(value) {
  match value {
    String(v) => v
    _ => raise DatabaseError::Decode(expected="String", actual=value)
  }
}

///|
pub impl FromSql for Bytes with fn from_sql(value) {
  match value {
    Bytes(v) => v
    _ => raise DatabaseError::Decode(expected="Bytes", actual=value)
  }
}

///|
pub impl FromSql for @time.ZonedDateTime with fn from_sql(value) {
  match value {
    Timestamp(v) => v
    _ =>
      raise DatabaseError::Decode(expected="@time.ZonedDateTime", actual=value)
  }
}

///|
pub impl FromSql for Json with fn from_sql(value) {
  match value {
    String(v) =>
      @json.parse(v) catch {
        _ => raise DatabaseError::Decode(expected="Json", actual=value)
      }
    _ => raise DatabaseError::Decode(expected="Json", actual=value)
  }
}

///|
pub impl[T : FromSql] FromSql for T? with fn from_sql(value) {
  match value {
    Null => None
    _ => Some(T::from_sql(value))
  }
}
