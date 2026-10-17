# Sessions

Sessions management.

## Middleware

```mbt nocheck
///|
async test {
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@sessions.middleware(@sessions.MemorySessionStore()))
    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap_or_error(
        Failure("require session"),
      )
      let count = session
        .get("count")
        .map(c => {
          match c {
            Json::Number(n, ..) => n.to_int()
            _ => 0
          }
        })
        .unwrap_or(0)
      session.set("count", Json(count + 1))
      res.send_text("Counter: \{count}")
    })
  })
  defer app.close()

  let server = @moonback.listen(port=3000)
  println("Server listening on \{server.addr}")
  app.serve(server)
}
```
