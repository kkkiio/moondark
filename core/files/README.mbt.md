# files

File storage abstraction with presigned upload and download URLs.

## Quick Start

```mbt check
///|
async test {
  let store = @files.LocalFileStore(root="/tmp/files-demo", key="app-secret")
  let app = @moonback.App(ctx => ctx.use_(store.routes()))
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let base = "http://127.0.0.1:\{server.addr.port()}"
    // Issue a presigned upload credential for direct client upload
    let upload = store.presign_put(key="docs/hello.txt", max_size=1024L)
    let (put_resp, _) = @http.put("\{base}\{upload.url}", "hello moondark")
    assert_eq(put_resp.code, 200)
    // Issue a presigned download URL for direct client download
    let url = store.presign_get(key="docs/hello.txt", download_name="hello.txt")
    let (get_resp, body) = @http.get("\{base}\{url}")
    assert_eq(get_resp.code, 200)
    assert_eq(body.text(), "hello moondark")
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}
```
