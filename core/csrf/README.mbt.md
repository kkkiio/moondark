# csrf

Stateless Cross-Site Request Forgery (CSRF) protection middleware based on `Sec-Fetch-Site` and `Origin` request headers.

## Quick Start

```mbt check
///|
async test {
  let app = @moonback.App(ctx => {
    ctx.add_middleware(
      @csrf.middleware(trusted_origins=["https://app.example.com"]),
    )
    ctx.post("/transfer", (_req, res) => res.send_text("ok"))
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let base = "http://127.0.0.1:\{server.addr.port()}"
    // Cross-site POST is rejected with 403
    let (denied, _) = @http.post("\{base}/transfer", "", headers={
      "sec-fetch-site": "cross-site",
    })
    assert_eq(denied.code, 403)
    // Same-origin POST is allowed with 200
    let (allowed, _) = @http.post("\{base}/transfer", "", headers={
      "sec-fetch-site": "same-origin",
    })
    assert_eq(allowed.code, 200)
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}
```
