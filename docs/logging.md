# MoonDark 日志实践

服务端错误可观测性的设计决策与日志规范。背景与问题清单见文末「背景」。

## 核心原则

### 1. 下层 wrap，上层 log（边界记录）

request–response 链路上，下层代码**不打印日志**：catch 到错误时，要么把原因
**wrap 进 suberror 变体的 `Error` 载荷**继续向上抛（如 `BadConn(e)`、
`ApplyFailed(name~, e)`），要么收窄 catch 只兜"预期的业务错误"、让基础设施
错误向上传播。日志统一在**边界**写：

- **HTTP 边界**：请求错误日志 middleware（第一个注册，`next() catch` 后
  `log.error` + `raise`），覆盖 handler 及所有下游 middleware 的 raise。
- **翻译边界**：把内部错误翻译成用户文案/HTTP 状态码的 catch 点
  （`SocialFlow::callback_handler`、csrf `deny_handler`、presigned 路由），
  在翻译前按级别记录。
- **后台边界**：Worker、连接池等无请求上下文的长循环，在"容错 or 死亡"
  的决策点记录。

### 2. catch 收窄到业务预期错误

catch `_` 把 DB 故障翻译成"用户不可用/已占用"这类业务结果是有害语义。
只兜声明过的业务错误（`AuthError`、`OAuthError`、`CsrfError`、`FileError`、
`SignError`），其余 `err => raise err` 交给 HTTP 边界。基础设施故障
应该表现为 500 + 日志，而不是误导性的 4xx。

### 3. 包装错误必须携带 cause

把低层错误翻译成领域错误时，携带 `Error` 载荷而不是只留文案。
`OAuthError::TokenExchangeFailed` 增加 `cause`（破坏性变更，0.x 允许，
`Eq` derive 需改为手写或移除）——底层网络错误（DNS/超时/TLS）不再被
"token endpoint unreachable" 吞掉。

### 4. 级别与 category 约定

告警卫生：`error` = 需要人工介入；能自愈的异常最高 `warn`
（配了告警的人不该为自动恢复的抖动起身排查）。

| 级别 | 用于 |
|---|---|
| `error` | 请求 500、翻译层收到的内部错误、worker store 持续不可用（超过窗口）、后台任务真正死亡 |
| `warn` | 业务预期或瞬时失败：OAuth 握手失败、CSRF 拒绝、签名伪造/损坏、BadConn 重试、worker store 单次失败、bcrypt hash 损坏、迁移 records 写入失败 |
| `debug` | 正常竞争与过期：session 并发登出、presign token 过期/格式坏、清理类 close/rollback 失败 |
| `info` | 显著状态变化：worker 从持续故障恢复、启动摘要 |
| `fatal` | 启动期配置错误（如 csrf middleware 构造失败） |

category 用模块路径：`moondark.auth`、`moondark.sessions`、`moondark.tasks`、
`moondark.database` 等。

### 5. 噪音控制 = 级别 + category，不在代码里加开关

社区惯例（Go `slog`、Rust `tracing`、Django `LOGGING` dict）一致：
**调用点自由打，靠 level + category 过滤**。tonyfettes-log 的
`Config`/`MOON_XLOG` 已支持按 category 调级，moondark 不引入
"日志开关"参数。

同步 stdout 输出的背压是可接受甚至想要的（宁可慢，不可丢）；
真正的泛洪点（worker 每次 attempt 一条 warn）本来就有 backoff
下限间隔，不构成刷屏。

## 错误在日志中的表示

`Event::write_object_field(key, value)` 要求 `value : ToJson`，而 `Error`
不实现 `ToJson`、也没有 `cause()` 访问器，目前只有 **`e.to_string()`**
一条路：`Error` 打印变体的 Debug repr，携带 `Error` 载荷的变体
（`BadConn`/`ApplyFailed`）会递归输出内层——不结构化、格式不可控，
但信息是全的。等 MoonBit 官方提供 error cause 访问器后再升级为
结构化链。

写法用 xlog 的官方惯用法——MoonBit 0.10 的条件模板写语法 `<?`：
`Event?` 为 `None`（级别/category 被关闭）时右侧**不求值**，
字段构造零成本；为 `Some` 时 `{ "k": v }` 字面量经
`write_object_begin/field/end` 展开。不为每个调用点封装 emit helper：

```moonbit
@xlog.error(category="moondark.tasks") <? {
  "error": e.to_string(),
  "task": task_name,
}
```

## 各点位决策

| 点位 | 决策 |
|---|---|
| 请求错误日志 middleware | 新建 `core/logging` 包导出 `middleware()`；应用第一个注册；`log.error` + `raise`（moonback `handle_request` 仍会回 500，见上游 issue [moonbitlang/moonback#7](https://github.com/moonbitlang/moonback/issues/7)） |
| `SocialFlow::callback_handler` | `authenticate` 的 `OAuthError` → warn + 502；`login_by_id`/`bind_oauth`/`login` 只兜 `AuthError`，其余传播 |
| `oauth2.mbt` | `TokenExchangeFailed`/`UserInfoFailed` 增加 `cause~ : Error`；移除 `derive(Eq)`（无容器/key 场景），测试 `assert_eq` 改 `is` 匹配断言；`InvalidTokenResponse` 保留原文本 |
| `bcrypt.verify` 失败 | 仍返回 `false`（防 oracle），warn——意味着 credentials 表损坏 |
| `mark_used` | debug（best-effort 是有意的） |
| `csrf` deny | middleware catch 时 warn 记录具体 variant |
| `presigner.verify` | 签名不匹配 → warn（伪造信号）；过期/格式坏 → debug |
| `Worker` store 失败 | 见下「Worker 容错策略」 |
| `task.func` 失败 | warn（task、attempt、error）+ 已有 `errors[]` 持久化 |
| pool `BadConn` 重试 / `reset_session` 失败 | warn / debug |
| `finish_record`/`ROLLBACK` 失败（migration） | warn |
| `session update` 返回 false → 400 | debug（并发登出是预期事件） |
| `session_store.get` raise | 不降级，500 + middleware 日志（fail-fast） |
| repage `csrf.middleware()` 构造失败 | fatal + raise，不 pass-through |

## Worker 容错策略

社区实践（Celery/Sidekiq/River/Oban）的共识是**退避重试不退出 + 单独
的健康通道**，靠 supervisor/k8s restartPolicy 兜崩溃，而不是 worker
自杀——repage 里 worker 与 web server 共享进程，自杀会把"DB 抖动
5 分钟"升级成"整站下线重启"。策略：

- `claim`/`save` 失败：退避重试（不退出），每次 `warn`；
- **心跳**：claim 成功更新 `last_success`（成本≈0），对外提供
  `Worker::last_heartbeat`/`is_healthy(window~)`，应用接进 `/healthz`
  供 k8s 探活；
- **持续故障升级**：`now - last_success` 超过窗口（默认 60s）时打一条
  `error`（此时才配告警），恢复时 `info`——瞬时抖动 `warn` 不告警，
  `error` 出现即真的需要人看；
- task group 失败导致 worker 真正死亡是另一回事：那确实该让进程退出，
  健康探活无法挽救已经死的协程。

不设 `max_*` 退出参数：心跳 + healthz 表达"不健康"比崩溃更精确，
k8s 从探活失败能学到同一件事。

`save` 失败的特殊语义：任务可能已执行完但结果没写回，重投会重复执行——
at-least-once 本来就接受这点，日志里写清楚 `save failed after task
executed`。

## Access log 字段（OTel semconv）

`core/logging` 的 middleware 除错误日志外同时承担 access log（`info`
级，可经 `MOON_XLOG` 调成 `debug` 或直接关掉）。字段对齐
[OTel HTTP semconv](https://opentelemetry.io/docs/specs/semconv/http/http-spans/)：

| 字段 | 说明 |
|---|---|
| `http.request.method` | 请求方法 |
| `url.path` | 请求路径（OTel 标记为安全默认字段） |
| `http.route` | **路由模板**而非具体路径——防高基数，access log 最有价值的字段；moonback `Request` 不暴露匹配模板（0.8.9），暂用 `url.path`，注意 id 型路径的基数问题 |
| `http.response.status_code` | 响应状态码；moonback `Responder` 是 `(Int, Headers) -> &WriteFlusher` 的 tuple struct，middleware 包一层即可截获（handler 未响应时为 0） |
| `http.server.request.duration` | 秒，float |
| `client.address` | 客户端地址 |
| `user_agent.original` | UA |

**query 两档**：presign token、OAuth `code`/`state` 都走 query。
（注：nginx/Apache 等传统 access log 全量打 URI，业界靠 token 短时效 +
一次性容忍；应用层日志可能外送第三方后端，故提供脱敏档。）

```moonbit
pub enum QueryLog { Full(redact~ : Array[String]); None }
```

- `Full`（默认）：打值，默认黑名单
  `["password","token","secret","signature","sig","key","code","state","credential","authorization"]`
  的值替换 `[FILTERED]`，应用可扩展；
- `None`：不打。

## 实现备忘（已落地）

- `http.route`：moonback 0.8.9 `Request` 无路由模板字段 → access log
  用 `url.path`。
- `status_code`：`Responder` 是 `async (Int, Headers) -> &WriteFlusher`
  tuple struct——middleware 内包一层 `(code, headers) => { status = code;
  res.respond(...) }` 即可截获（与上游 `unstable_logreq` 同手法）。
- 事件字段有条件项（`error`/`url.query`/`client.address`/
  `user_agent.original`），`<?` map 字面量放不下 → 用
  `if @xlog.error(...) is Some(ev)` + `write_object_field` 逐字段写；
  无条件字段的场景仍优先 `<?` 写法。

## 背景

错误不可观测的三层黑洞：

1. **HTTP 层**：moonback 0.8.9 `AppInst::handle_request` 吞掉所有 handler
   错误（源码带 `// TODO: log the error`），只回裸 500。已提上游 issue：
   [moonbitlang/moonback#7](https://github.com/moonbitlang/moonback/issues/7)。
2. **后台层**：`spawn_bg(allow_failure=true)` 失败的协程无人 `wait`，
   错误静默丢弃（async 0.22.5 `coroutine.mbt`）——worker、连接任务死亡
   不可见。可通过自身 catch + log 绕过，不提上游。
3. **翻译层**：moondark 自己的 catch-all 把内部错误翻成用户文案
   （`social.mbt`）或静态字符串（`oauth2.mbt`），原因丢失。

依赖：`tonyfettes/xlog`（repo: moonbit-community/tonyfettes-log，
experimental 同步 logger，global logger + `MOON_XLOG` 配置）。
