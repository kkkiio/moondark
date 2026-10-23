///|
/// `check_key` 拒绝的 key 形态（贯穿 put/presign 两条入口）。
async test "invalid keys are rejected" {
  let root = "/tmp/moondark-files-invalid-keys"
  let store = @files.CasFileStore::new(
    root~,
    catalog=@files.MemoryCatalog::new(),
    key="test-secret",
  )
  for bad in ["", "/abs", "a//b", "a/./b", "../x", "a/../b", "a\\b", "a\u0000b"] {
    let err : @files.FileError? = try {
      ignore(store.presign_put(key=bad))
      None
    } catch {
      e => Some(e)
    }
    assert_true(err is Some(@files.InvalidKey(_)), msg="key: \{bad}")
  }
}

///|
async test "presigned upload/download roundtrip over http" {
  let root = @fs.tmpdir(prefix="moondark-files")
  let store = @files.CasFileStore::new(
    root~,
    catalog=@files.MemoryCatalog::new(),
    key="test-secret",
  )
  let app = @moonback.App(ctx => ctx.use_(store.routes()))
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let base = "http://127.0.0.1:\{server.addr.port()}"
    // presign_put -> frontend PUTs raw bytes -> stored on disk
    let upload = store.presign_put(
      key="docs/hello.txt",
      content_type="text/plain",
      max_size=1024L,
    )
    assert_eq(upload.meth, @http.RequestMethod::Put)
    assert_eq(upload.headers, { "Content-Type": "text/plain" })
    let (put_resp, _) = @http.put("\{base}\{upload.url}", "hello moondark", headers={
      "Content-Type": "text/plain",
    })
    assert_eq(put_resp.code, 200)
    assert_true(store.exists(key="docs/hello.txt"))
    // presign_get -> anyone holding the URL downloads the file
    let url = store.presign_get(key="docs/hello.txt")
    let (get_resp, body) = @http.get("\{base}\{url}")
    assert_eq(get_resp.code, 200)
    assert_eq(
      get_resp.headers[@http.CaseInsensitiveString("content-type")],
      "text/plain",
    )
    assert_eq(body.text(), "hello moondark")
    // download_name sets Content-Disposition
    let named = store.presign_get(
      key="docs/hello.txt",
      download_name="报告 v2.txt",
    )
    let (named_resp, _) = @http.get("\{base}\{named}")
    assert_eq(named_resp.code, 200)
    let disposition = named_resp.headers[@http.CaseInsensitiveString(
        "content-disposition",
      )]
    assert_true(disposition.has_prefix("attachment; filename="))
    assert_true(disposition.contains("filename*=UTF-8''"))
    // missing object -> 404
    let missing = store.presign_get(key="docs/nope.txt")
    let (missing_resp, _) = @http.get("\{base}\{missing}")
    assert_eq(missing_resp.code, 404)
    // tampered token -> 403
    let (tampered_resp, _) = @http.get("\{base}\{url}x")
    assert_eq(tampered_resp.code, 403)
    // oversized upload -> 413 (Content-Length pre-check)
    let big = store.presign_put(key="big.bin", max_size=4L)
    let (big_resp, _) = @http.put("\{base}\{big.url}", "0123456789")
    assert_eq(big_resp.code, 413)
    assert_false(store.exists(key="big.bin"))
    // content-type must match the signed claim
    let typed = store.presign_put(key="typed.bin", content_type="image/png")
    let (mismatch_resp, _) = @http.put("\{base}\{typed.url}", "x", headers={
      "Content-Type": "text/plain",
    })
    assert_eq(mismatch_resp.code, 403)
    let (missing_ct_resp, _) = @http.put("\{base}\{typed.url}", "x")
    assert_eq(missing_ct_resp.code, 403)
    assert_false(store.exists(key="typed.bin"))
    // a failed upload must not clobber an existing object
    let overwrite = store.presign_put(key="docs/hello.txt", max_size=4L)
    let (ow_resp, _) = @http.put("\{base}\{overwrite.url}", "0123456789")
    assert_eq(ow_resp.code, 413)
    let (still_resp, still_body) = @http.get("\{base}\{url}")
    assert_eq(still_resp.code, 200)
    assert_eq(still_body.text(), "hello moondark")
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
async test "presigned url expires" {
  let mut now = 1_000_000L
  let root = @fs.tmpdir(prefix="moondark-files-exp")
  let store = @files.CasFileStore::new(
    root~,
    catalog=@files.MemoryCatalog::new(),
    key="test-secret",
    now=() => now,
  )
  let app = @moonback.App(ctx => ctx.use_(store.routes()))
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let base = "http://127.0.0.1:\{server.addr.port()}"
    let url = store.presign_get(key="a.txt", expires=60L)
    store.put(key="a.txt", "hi")
    // still valid at exactly the expiry boundary
    now = 1_000_060L
    let (ok_resp, _) = @http.get("\{base}\{url}")
    assert_eq(ok_resp.code, 200)
    // past expiry -> 403
    now = 1_000_061L
    let (expired_resp, _) = @http.get("\{base}\{url}")
    assert_eq(expired_resp.code, 403)
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}
