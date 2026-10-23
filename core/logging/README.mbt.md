# moondark/logging

请求级日志中间件：access log（OTel 字段）+ handler 错误兜底记录。

## Quick Start

```mbt check
///|
/// 第一个注册（最外层），才能覆盖其它 middleware 抛出的错误。
pub fn logging_middleware() -> @moonback.Middleware {
  @logging.middleware()
}
```

```mbt nocheck
ctx.add_middleware(@logging.middleware())
```

- 成功请求：`info` 级一条，带 `http.request.method`、`url.path`、
  `http.response.status_code`、`http.server.request.duration`、
  `client.address`、`user_agent.original`；
- handler 抛错：`error` 级一条（含 `error` 字段）后继续向上抛，
  moonback 仍回 500；
- `?query` 里的 `token`/`code`/`state` 等敏感参数默认脱敏为
  `[FILTERED]`（`QueryLog::Full`），`QueryLog::None` 完全不打。

日志输出走 `tonyfettes/xlog` 的 global logger，应用在 main 里配置
`MOON_XLOG` 或 `set_handler`/`set_level`。约定见 `docs/logging.md`。
