///|
pub(open) trait Driver {
  fn open(Self, String) -> &Connector raise
}

///|
pub(open) trait Connector {
  async fn connect(Self) -> &Conn
}

///|
pub(open) trait Conn {
  async fn prepare(Self, String) -> &Stmt
  async fn close(Self) -> Unit
  async fn begin(Self) -> &Tx
}

///|
pub(open) trait Stmt {
  async fn close(Self) -> Unit
  fn num_input(Self) -> Int32
  async fn exec(Self, Array[Value]) -> Unit
  async fn query(Self, Array[Value]) -> &Rows
}

///|
pub(open) trait Tx {
  async fn commit(Self) -> Unit
  async fn rollback(Self) -> Unit
}

///|
pub(open) trait Rows {
  fn columns(Self) -> Array[String]
  async fn close(Self) -> Unit
  async fn next(Self, dest : Array[Value]) -> Bool
}

///|
pub(all) enum Value {
  Null
  Bool(Bool)
  Int64(Int64)
  Double(Double)
  String(String)
  Bytes(Bytes)
  Timestamp(@time.ZonedDateTime)
} derive(Debug)

///|
pub extend Value with Debug::{to_repr}

///|
pub(open) trait Valuer {
  fn to_value(Self) -> Value
}

///|
pub impl Valuer for Bool with fn to_value(self) -> Value {
  Value::Bool(self)
}

///|
pub impl Valuer for Int64 with fn to_value(self) -> Value {
  Value::Int64(self)
}

///|
pub impl Valuer for Double with fn to_value(self) -> Value {
  Value::Double(self)
}

///|
pub impl Valuer for String with fn to_value(self) -> Value {
  Value::String(self)
}

///|
pub impl Valuer for Bytes with fn to_value(self) -> Value {
  Value::Bytes(self)
}

///|
pub impl Valuer for @time.ZonedDateTime with fn to_value(self) -> Value {
  Value::Timestamp(self)
}
