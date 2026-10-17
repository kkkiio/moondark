///|
priv struct MockAnswerDB {
  mut last_prepared : String
  executed : Array[Array[@driver.Value]]
}

///|
fn MockAnswerDB::MockAnswerDB() -> MockAnswerDB {
  { last_prepared: "", executed: [], }
}

///|
impl @driver.Connector for MockAnswerDB with fn connect(self) {
  self
}

///|
impl @driver.Conn for MockAnswerDB with fn prepare(self, query) {
  self.last_prepared = query
  self
}

///|
impl @driver.Conn for MockAnswerDB with fn close(self) {
  ignore(self)
}

///|
impl @driver.Conn for MockAnswerDB with fn begin(self) {
  ignore(self)
  fail("not supported")
}

///|
impl @driver.Stmt for MockAnswerDB with fn close(self) {
  ignore(self)
}

///|
impl @driver.Stmt for MockAnswerDB with fn num_input(self) {
  ignore(self)
  -1
}

///|
impl @driver.Stmt for MockAnswerDB with fn exec(self, args) {
  self.executed.push(args)
  @driver.ExecResult::{ rows_affected: Some(1), last_insert_id: None, }
}

///|
impl @driver.Stmt for MockAnswerDB with fn query(self, args) {
  ignore(self)
  ignore(args)
  MockAnswerDBRows::{ index: 0, }
}

///|
priv struct MockAnswerDBRows {
  mut index : Int32
}

///|
impl @driver.Rows for MockAnswerDBRows with fn columns(self) {
  ignore(self)
  ["question", "answer"]
}

///|
impl @driver.Rows for MockAnswerDBRows with fn next(self, dest) {
  guard self.index < 1 else { return false }
  dest[0] = @driver.Value::String(
    "Answer to the Ultimate Question of Life, the Universe, and Everything",
  )
  dest[1] = @driver.Value::String("42")
  self.index += 1
  true
}

///|
impl @driver.Rows for MockAnswerDBRows with fn close(self) {
  ignore(self)
}
