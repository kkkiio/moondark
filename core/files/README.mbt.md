# files

`xziheng/moondark/files` 是文件/附件存储抽象：以预签名 URL（Presigned URL）为核心能力，前端直传、后端不中转文件字节流，本地磁盘与对象存储后端可互换。

## Quick Start

`LocalFileStore` 把对象存在本地磁盘，presigned URL 由 `routes()` 挂载的
直传路由兑现（`PUT <url_prefix>/put/<token>` 上传、`GET <url_prefix>/get/<token>`
下载，token 是 `@signing` 签出的自包含凭证）：

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
    // 签发上传凭证，前端按 url/meth/headers 直传
    let upload = store.presign_put(key="docs/hello.txt", max_size=1024L)
    let (put_resp, _) = @http.put("\{base}\{upload.url}", "hello moondark")
    assert_eq(put_resp.code, 200)
    // 签发下载 URL，持有者可直取，后端不中转
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

## 后端接口

`FileStore` 是后端抽象，`filestest.check_file_store` 是各后端共用的
conformance suite（对齐 `sessionstest`）：

- `presign_put` / `presign_get`：签发带 `exp` 过期时间的直传/直取凭证。
- `put` / `get` / `exists` / `delete`：后端直读直写的小文件路径。
- `LocalFileStore`：本地磁盘后端，对象在 `<root>/objects/<key>`，
  `Content-Type` 元数据在 `<root>/meta/<key>`；key 会校验为安全的
  相对路径（拒绝 `..`、绝对路径、`\`、空分段）。
