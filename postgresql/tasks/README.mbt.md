# moondark_postgresql/tasks

`PostgresTaskBackend` 是 `xziheng/moondark/tasks` 契约
（`DBTaskBackend` + `TaskStore`）的 PostgreSQL 实现：任务结果存进
一张 `task_results` 表，worker 轮询同一张表领取并执行。生产者和
worker 可以同进程也可以不同进程，共享的只有这张表。

## 建表

`migrate()` 创建结果表与认领索引（部分索引，只覆盖
`ready`/`running` 行）：

```mbt nocheck
let backend = @tasks.PostgresTaskBackend::new(db)
backend.migrate()
```

`table` 参数会原样拼进 SQL，必须是可信标识符；`now` 默认取墙钟
毫秒，测试里可注入。

## 投递

`enqueue` 是往调用方事务里写一条 `INSERT`——任务行与业务写入一起
提交或回滚（transactional outbox）：

```mbt nocheck
///|
let email : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
  name="send_email",
)

///|
let id = db.with_transaction(tx => {
  // ... 业务写入 ...
  email.enqueue_on(backend, tx, args={ "to": "user@example.com" })
})
```

返回任务 id；`def.get_result(backend, id)` 按名字和 id 读回
`TaskResult`；`JSONB` 列以 JSON 文本返回并在驱动层之上重新解析。

## 认领（claim）

`claim` 是单条原子 `UPDATE`：子查询按 `enqueued_at` 先入先出选出
一条可运行的 `ready` 行（`run_after` 为空或已到期），或一条仍在
`max_attempts` 预算内的过期 `running` 行（属于中途死掉的 worker）；
`FOR UPDATE SKIP LOCKED` 让并发 worker 跳过彼此已锁的行而不是互相
阻塞。`stale_before=None` 时绝不回收过期行。

`save` 把 `TaskResult` 的可变字段（status、run_after、started_at、
finished_at、attempts、return_value、errors、worker_ids）写回该行。

## Worker

```mbt nocheck
let worker = @moondark_tasks.Worker::new(
  store=backend,
  tasks=[@moondark_tasks.TaskExec::from_def(email, func=(_ctx, args) => args)],
  reclaim_after=Some(300_000), // 5 分钟未完成的 running 行可被回收
)
group.spawn_bg(no_wait=true, () => worker.run())
```

`run_once` 是 `run` 循环的单步：认领、执行、保存。失败在重试预算
内回到 `ready`（`run_after = now + backoff(attempt)`），预算耗尽则
落为 `failed`。
