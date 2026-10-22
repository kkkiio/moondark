# tasks

`xziheng/moondark/tasks` 任务框架契约的 SQLite 实现：
`SqliteTaskBackend` 同时实现 `DBTaskBackend`（enqueue / get_result）
与 `TaskStore`（claim / save），每条 `TaskResult` 对应表中的一行，
`args`、`return_value`、`errors`、`worker_ids` 以 JSON 文本存储。

## 建表与投递

```mbt nocheck
@async.with_task_group(group => {
  let (db, executor) = @sqlite_database.open_db("app.db")
  group.spawn_bg(no_wait=true, () => executor.run())
  db.ready()
  defer db.close()
  let backend = @sqlite_tasks.SqliteTaskBackend::new(db)
  backend.migrate()

  let email : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
    name="send_email",
  )
  // 投递只有一种方式：把任务行写进调用方的事务。
  // 与业务写入一起提交或回滚，worker 只能同时看到两者或都看不到。
  let id = db.with_transaction(tx => {
    // ... 业务写入 ...
    email.enqueue_on(backend, tx, args={ "to": "user@example.com" })
  })
})
```

`enqueue_on` 是单条 `INSERT`，返回任务 id；`run_after` 参数指定
延迟执行。查询结果用 `def.get_result(backend, id)`。

## Worker

`Worker` 轮询 `claim` 抢任务执行；`claim` 是单条
`UPDATE ... WHERE id = (SELECT ... LIMIT 1) RETURNING ...`：
SQLite 串行化写者，子查询选行与更新天然原子，不需要 `FOR UPDATE`。

```mbt nocheck
let worker = @tasks.Worker::new(
  store=backend,
  tasks=[@tasks.TaskExec::from_def(email, func=(_ctx, args) => args)],
)
group.spawn_bg(no_wait=true, () => worker.run())
```

- 选行按 `enqueued_at` 先入先出；`run_after` 未到的行不会被认领。
- `reclaim_after=Some(d)` 把 `started_at` 早于 `now - d` 的 `Running`
  行当作崩溃 worker 的遗物重新认领；`None` 则永不回收。
- 失败后在行的 `max_attempts` 预算内按 `backoff` 重排为 `Ready`，
  预算耗尽记为 `Failed`；每次认领把 worker id 追加进 `worker_ids`。

`migrate` 建表的同时设置 `PRAGMA busy_timeout`（5000ms），让并发
写者重试而不是直接报 `SQLITE_BUSY`。注意 busy_timeout 是
per-connection 的，只对跑过 `migrate` 的那条池连接生效。
