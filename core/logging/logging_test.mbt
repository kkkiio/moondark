///|
struct MemoryHandler {
  entries : Array[@xlog.Entry]
}

///|
impl @xlog.Handler for MemoryHandler with fn handle(self, entry) {
  self.entries.push(entry)
}

///|
/// All entries this test binary logs. Installed once at startup: async
/// tests run concurrently, so swapping the global handler per test would
/// race and leak entries between them.
let entries : Array[@xlog.Entry] = []

///|
fn init {
  @xlog.global().set_handler(MemoryHandler::{ entries, })
  @xlog.global().set_level(@xlog.Trace)
}

///|
fn field(entry : @xlog.Entry, name : String) -> Json? {
  entry.fields.get(name)
}

///|
fn entry_for(entries : Array[@xlog.Entry], path : String) -> @xlog.Entry? {
  for e in entries {
    if field(e, "url.path") is Some(String(p)) && p == path {
      return Some(e)
    }
  }
  None
}

///|
/// The middleware emits after `next` returns, which can lag the client's
/// `http.get` — poll briefly instead of racing it.
async fn wait_entry(
  entries : Array[@xlog.Entry],
  path : String,
) -> @xlog.Entry? {
  for _ in 0..<50 {
    if entry_for(entries, path) is Some(e) {
      return Some(e)
    }
    @async.sleep(10)
  }
  None
}

///|
/// Serve `app` on an ephemeral port, run `f` against its base URL, then
/// shut everything down.
async fn with_server(app : @moonback.App, f : async (String) -> Unit) -> Unit {
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    let task = group.spawn(() => app.serve(server))
    f("http://127.0.0.1:\{server.addr.port()}")
    task.cancel()
    task.wait() catch {
      _ => ()
    }
    server.close()
  })
}

///|
async test "middleware logs access fields and handler errors" {
  let app = @moonback.App(
    @moonback.Module(ctx => {
      ctx.add_middleware(@logging.middleware())
      ctx.get("/ok", (_req, res) => res.send_text("ok"))
      ctx.get("/boom", (_req, _res) => fail("boom"))
    }),
  )
  with_server(app, base => {
    ignore(@http.get("\{base}/ok"))
    let (response, _) = @http.get("\{base}/boom")
    assert_eq(response.code, 500)
  })
  // access log: one info entry carrying the OTel fields
  guard wait_entry(entries, "/ok") is Some(ok) else {
    fail("expect an access entry for /ok")
  }
  assert_true(ok.level == @xlog.Info)
  assert_eq(field(ok, "http.request.method"), Some(Json::string("GET")))
  assert_eq(field(ok, "http.response.status_code"), Some(Json::number(200.0)))
  guard field(ok, "http.server.request.duration") is Some(Number(_, ..)) else {
    fail("expect duration field")
  }
  // error log: the raised error is recorded, then moonback answers 500
  guard wait_entry(entries, "/boom") is Some(boom) else {
    fail("expect an error entry for /boom")
  }
  assert_true(boom.level == @xlog.Error)
  guard field(boom, "error") is Some(String(msg)) && msg.contains("boom") else {
    fail("expect the propagated error in the entry")
  }
}

///|
async test "middleware redacts sensitive query params" {
  let app = @moonback.App(
    @moonback.Module(ctx => {
      ctx.add_middleware(@logging.middleware())
      ctx.get("/cb-redact", (_req, res) => res.send_void(status=204))
    }),
  )
  with_server(app, base => {
    ignore(@http.get("\{base}/cb-redact?code=abc123&state=xyz&keep=1"))
  })
  guard wait_entry(entries, "/cb-redact") is Some(entry) else {
    fail("expect an access entry")
  }
  guard field(entry, "url.query") is Some(String(query)) else {
    fail("expect url.query field")
  }
  assert_true(query.contains("code=[FILTERED]"))
  assert_true(query.contains("state=[FILTERED]"))
  assert_true(query.contains("keep=1"))
}

///|
async test "QueryLog::None omits url.query" {
  let app = @moonback.App(
    @moonback.Module(ctx => {
      ctx.add_middleware(@logging.middleware(query=@logging.QueryLog::None))
      ctx.get("/cb-none", (_req, res) => res.send_void(status=204))
    }),
  )
  with_server(app, base => ignore(@http.get("\{base}/cb-none?code=abc")))
  guard wait_entry(entries, "/cb-none") is Some(entry) else {
    fail("expect an access entry")
  }
  assert_eq(field(entry, "url.query"), None)
}
