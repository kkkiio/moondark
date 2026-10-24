///|
priv struct RetryLogHandler {
  entries : Array[@xlog.Entry]
}

///|
impl @xlog.Handler for RetryLogHandler with fn handle(self, entry) {
  self.entries.push(entry)
}

///|
let retry_entries : Array[@xlog.Entry] = []

///|
fn init {
  @xlog.global().set_handler(RetryLogHandler::{ entries: retry_entries, })
  @xlog.global().set_level(@xlog.Trace)
}

///|
fn logs_for(cause : String) -> Array[@xlog.Entry] {
  retry_entries.filter(entry => {
    entry.fields.get("error") is Some(String(message)) &&
    message.contains(cause)
  })
}

///|
fn check_retry_log(
  cause : String,
  message : String,
  count : Int32,
) -> Unit raise {
  let entries = logs_for(cause)
  assert_eq(entries.length(), count)
  for index, entry in entries {
    assert_true(entry.level == @xlog.Warn)
    assert_eq(entry.category, Some("moondark.database"))
    assert_eq(entry.fields.get("attempt"), Some(Json(index + 1)))
    guard entry.fields.get("message") is Some(String(actual)) else {
      fail("missing retry message")
    }
    assert_true(actual.contains(message))
  }
}

///|
async test "BadConn retries log warnings for acquisition, execution and scoped startup" {
  let connector = MockConnector()
  connector.fail_connect = Some(@driver.BadConn(Failure("retry-log-acquire")))
  run_db(@database.DB::create(connector, max_open=1), db => {
    try db.ping() catch {
      @driver.BadConn(_) => ()
      e => raise e
    } noraise {
      _ => fail("expected acquisition failure")
    }
    check_retry_log("retry-log-acquire", "retrying operation", 2)
  })
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_open=1), db => {
    db.ping()
    connector.conns[0].fail_exec = Some(
      @driver.BadConn(Failure("retry-log-execute")),
    )
    ignore(db.execute("UPDATE"))
    check_retry_log("retry-log-execute", "retrying operation", 1)
  })
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_open=1), db => {
    db.ping()
    connector.conns[0].fail_begin = Some(
      @driver.BadConn(Failure("retry-log-transaction")),
    )
    let mut calls = 0
    db.with_transaction(_ => calls += 1)
    assert_eq(calls, 1)
    check_retry_log("retry-log-transaction", "transaction startup", 1)
  })
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_open=1), db => {
    db.ping()
    connector.conns[0].fail_prepare = Some(
      @driver.BadConn(Failure("retry-log-stream")),
    )
    let mut calls = 0
    db.with_stream("SELECT", _ => calls += 1)
    assert_eq(calls, 1)
    check_retry_log("retry-log-stream", "stream startup", 1)
    let callback : async (@database.RowStream) -> Unit = _ => {
      raise @driver.BadConn(Failure("retry-log-callback"))
    }
    try db.with_stream("SELECT", callback) catch {
      @driver.BadConn(_) => ()
      e => raise e
    } noraise {
      _ => fail("expected callback failure")
    }
    assert_eq(logs_for("retry-log-callback").length(), 0)
  })
}
