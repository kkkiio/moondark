///|
/// 对齐 Go `TestCrossOriginProtectionAddTrustedOriginErrors` 的全部用例。
test "trusted_origins validation aligns with Go TestCrossOriginProtectionAddTrustedOriginErrors" {
  let cases : Array[(String, Bool)] = [
    ("https://example.com", false),
    ("https://example.com:8080", false),
    ("http://example.com", false),
    ("example.com", true),
    ("https://", true),
    ("://example.com", true),
    ("https://@example.com", true),
    ("https://foo:bar@example.com", true),
    ("https://example.com/", true),
    ("https://example.com/path", true),
    ("https://example.com?query=value", true),
    ("https://example.com#fragment", true),
    ("https://ex ample.com", true),
    ("ht/tp://example.com", true),
    ("", true),
    ("null", true),
  ]
  for case in cases {
    let (origin, want_err) = case
    let err : @csrf.CsrfError? = try {
      ignore(@csrf.CrossOriginProtection(trusted_origins=[origin]))
      None
    } catch {
      e => Some(e)
    }
    if want_err {
      assert_eq(err, Some(@csrf.InvalidOrigin(origin)))
    } else {
      assert_eq(err, None)
    }
  }
}

///|
/// 对齐 Go `TestCrossOriginProtectionSecFetchSite` 的全部用例，并验证 `check` 的具体错误类型。
async test "CrossOriginProtection::check aligns with Go TestCrossOriginProtectionSecFetchSite" {
  let cop = @csrf.CrossOriginProtection()
  let last_result : Ref[Result[Unit, @csrf.CsrfError]?] = { val: None, }
  let handler : @moonback.Handler = (req, res) => {
    let r : Result[Unit, @csrf.CsrfError] = Ok(cop.check(req)) catch {
      e => Err(e)
    }
    last_result.val = Some(r)
    match r {
      Ok(_) => res.send_void(status=200)
      Err(_) => res.send_void(status=403)
    }
  }
  let app = @moonback.App(ctx => {
    ctx.get("/", handler)
    ctx.add_route(@http.RequestMethod::Head, "/", handler)
    ctx.add_route(@http.RequestMethod::Options, "/", handler)
    ctx.post("/", handler)
    ctx.add_route(@http.RequestMethod::Put, "/", handler)
    ctx.add_route(@http.RequestMethod::Delete, "/", handler)
  })
  defer app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let port = server.addr.port()
    let url = "http://127.0.0.1:\{port}/"
    let cases : Array[
      (
        @http.RequestMethod,
        String,
        String,
        Int32,
        Result[Unit, @csrf.CsrfError],
      ),
    ] = [
      // Sec-Fetch-Site header cases
      (@http.RequestMethod::Post, "same-origin", "", 200, Ok(())),
      (@http.RequestMethod::Post, "none", "", 200, Ok(())),
      (
        @http.RequestMethod::Post,
        "cross-site",
        "",
        403,
        Err(@csrf.CrossOriginWrite),
      ),
      (
        @http.RequestMethod::Post,
        "same-site",
        "",
        403,
        Err(@csrf.CrossOriginWrite),
      ),
      // No Sec-Fetch-Site header -> Origin fallback cases
      (@http.RequestMethod::Post, "", "", 200, Ok(())),
      (@http.RequestMethod::Post, "", "http://127.0.0.1:\{port}", 200, Ok(())),
      (@http.RequestMethod::Post, "", "https://127.0.0.1:\{port}", 200, Ok(())),
      (
        @http.RequestMethod::Post,
        "",
        "https://attacker.example",
        403,
        Err(@csrf.OriginMismatch),
      ),
      (@http.RequestMethod::Post, "", "null", 403, Err(@csrf.OriginMismatch)),
      // Safe vs unsafe HTTP methods
      (@http.RequestMethod::Get, "cross-site", "", 200, Ok(())),
      (@http.RequestMethod::Head, "cross-site", "", 200, Ok(())),
      (@http.RequestMethod::Options, "cross-site", "", 200, Ok(())),
      (
        @http.RequestMethod::Put,
        "cross-site",
        "",
        403,
        Err(@csrf.CrossOriginWrite),
      ),
      (
        @http.RequestMethod::Delete,
        "cross-site",
        "",
        403,
        Err(@csrf.CrossOriginWrite),
      ),
    ]
    for case in cases {
      let (meth, sec_fetch_site, origin, expected_status, expected_res) = case
      let headers : Map[@http.CaseInsensitiveString, String] = Map([])
      if !sec_fetch_site.is_empty() {
        headers["sec-fetch-site"] = sec_fetch_site
      }
      if !origin.is_empty() {
        headers["origin"] = origin
      }
      let (resp, _) = @http.request(url, meth, headers, "")
      assert_eq(resp.code, expected_status)
      assert_eq(last_result.val, Some(expected_res))
    }
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}

///|
/// 对齐 Go `TestCrossOriginProtectionTrustedOriginBypass` 与 `TestCrossOriginProtectionSetDenyHandler`。
async test "csrf middleware aligns with Go TrustedOriginBypass and SetDenyHandler" {
  let app = @moonback.App(ctx => {
    ctx.add_middleware(
      @csrf.middleware(trusted_origins=["https://trusted.example"]),
    )
    ctx.get("/", (_req, res) => res.send_text("ok"))
    ctx.post("/", (_req, res) => res.send_text("ok"))
  })
  defer app.close()
  let custom_app = @moonback.App(ctx => {
    ctx.add_middleware(
      @csrf.middleware(deny_handler=(_req, res) => {
        res.send_text("custom error", status=418)
      }),
    )
    ctx.get("/", (_req, res) => res.send_text("ok"))
    ctx.post("/", (_req, res) => res.send_text("ok"))
  })
  defer custom_app.close()
  @async.with_task_group(group => {
    let server = @moonback.listen(port=0)
    defer server.close()
    let serve_task = group.spawn(() => app.serve(server))
    let url = "http://127.0.0.1:\{server.addr.port()}/"
    // TestCrossOriginProtectionTrustedOriginBypass cases
    let bypass_cases : Array[(String, String, Int32)] = [
      ("https://trusted.example", "", 200),
      ("https://trusted.example", "cross-site", 200),
      ("https://attacker.example", "", 403),
      ("https://attacker.example", "cross-site", 403),
    ]
    for case in bypass_cases {
      let (origin, sec_fetch_site, expected_status) = case
      let headers : Map[@http.CaseInsensitiveString, String] = {
        "origin": origin,
      }
      if !sec_fetch_site.is_empty() {
        headers["sec-fetch-site"] = sec_fetch_site
      }
      let (resp, _) = @http.post(url, "", headers~)
      assert_eq(resp.code, expected_status)
    }
    serve_task.cancel()
    serve_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }

    // TestCrossOriginProtectionSetDenyHandler cases
    let custom_server = @moonback.listen(port=0)
    defer custom_server.close()
    let custom_task = group.spawn(() => custom_app.serve(custom_server))
    let custom_url = "http://127.0.0.1:\{custom_server.addr.port()}/"
    let (denied_resp, denied_body) = @http.post(custom_url, "", headers={
      "sec-fetch-site": "cross-site",
    })
    assert_eq(denied_resp.code, 418)
    assert_eq(denied_body.text(), "custom error")
    let (get_resp, _) = @http.get(custom_url)
    assert_eq(get_resp.code, 200)
    custom_task.cancel()
    custom_task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
}
