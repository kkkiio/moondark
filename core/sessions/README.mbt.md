# sessions

Cookie-backed HTTP session middleware with pluggable storage backends.

## Quick Start

```mbt nocheck
///|
async test {
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(@sessions.MemorySessionStore()))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      let count = match session["count"] {
        Some(Number(n, ..)) => n.to_int() + 1
        _ => 1
      }
      session["count"] = Json(count)
      res.send_text("Counter: \{count}")
    })
  })
  defer app.close()

  let server = @moonback.listen(port=3000)
  app.serve(server)
}
```
