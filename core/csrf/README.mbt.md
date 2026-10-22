# csrf

`xziheng/moondark/csrf` 提供基于 Fetch Metadata（`Sec-Fetch-Site`）与 `Origin` 请求头的无状态跨站请求伪造（CSRF）防护中间件（对齐 Go 1.25 `net/http.CrossOriginProtection`），无需签发或存储 CSRF Token 即可拦截跨源写请求。

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
    // 跨站 POST 被拦截，返回 403
    let (denied, _) = @http.post("\{base}/transfer", "", headers={
      "sec-fetch-site": "cross-site",
    })
    assert_eq(denied.code, 403)
    // 同源 POST 放行，返回 200
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
