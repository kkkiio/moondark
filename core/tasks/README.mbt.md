# Tasks

基于 `database/sql` 的后台任务队列，参考 Django `django.tasks`（DEP 0014）
与 River 的事务型投递。任务表和业务表在同一个数据库里：enqueue 是往
调用方事务里 `INSERT` 一行，worker 轮询同一张表执行任务。

## 定义与投递

任务分两半声明。`TransactionalTaskDef[T]` 是**生产侧句柄**：名字 +
重试预算 + 参数类型 `T`，不含函数——发任务的进程不需要知道任务怎么
执行。`T` 一次声明，两端类型安全：`enqueue_on` 要求 `T : ToJson`，
worker 侧 `TaskExec::from_def` 要求 `T : FromJson`。

```mbt check
///|
async test {
  let email : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
    name="send_email",
    max_attempts=3,
  )
  let backend = @tasks.DummyBackend::new() // 内存实现；真库用各驱动模块
  let (db, executor) = @sqltest.FakeConnector::new().open_db()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    // 生产侧：任务行和业务写入在同一个事务里提交或回滚，
    // worker 只能同时看到两者或都看不到（transactional outbox）
    let id = db.with_transaction(tx => {
      // ... 业务写入 ...
      email.enqueue_on(backend, tx, args={ "to": "user@example.com" })
    })
    assert_true(email.get_result(backend, id) is Some(_))
  })
}
```

`enqueue_on` 返回任务 id；`run_after` 参数可指定延迟执行的 unix-ms
时间戳。投递后想查状态（比如前端轮询"报表生成好了没"）用
`def.get_result(backend, id)`——`TaskResult` 是某一刻的不可变快照，
再调一次就是新状态。

## Worker

`TaskExec` 是 **worker 侧注册项**：同一个 def + 真正执行的函数。
函数拿到 `TaskContext`（当前 `TaskResult` 和 1-based `attempt`）和
解码后的 `T`，返回 `Json` 存为 `return_value`：

```mbt check
///|
async test {
  let def : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
    name="echo",
  )
  let backend = @tasks.DummyBackend::new()
  let (db, executor) = @sqltest.FakeConnector::new().open_db()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    ignore(
      db.with_transaction(tx => def.enqueue_on(backend, tx, args={ "n": 21 })),
    )
    let worker = @tasks.Worker::new(store=backend, tasks=[
      @tasks.TaskExec::from_def(def, func=(_ctx, args) => {
        // ... 这里写真实的副作用，返回值存进任务行 ...
        Json::object({ "got": args })
      }),
    ])
    assert_true(worker.run_once())
  })
}
```

`worker.run()` 是常驻轮询循环（drain 后按 `poll_interval` 休眠），
用 `group.spawn_bg` 挂到服务进程的 task group 上；`run_once()` 执行
一个任务，适合批量模式与测试。

## 投递语义

投递保证由两层拼出，**enqueue 的事务位置** + **worker 的重试/回收**：

- 任务行和业务写同事务提交 ⇒ 不会"数据在但任务丢了"，也不会
  "任务跑了但数据没提交"。这是 `enqueue_on` 强制的，也是
  at-least-once 的投递基础。
- `max_attempts` 是行的执行预算：失败后按 `backoff` 重排到
  `Ready`，预算耗尽记 `Failed`。
- `Worker.reclaim_after` 回收僵尸行：worker claim 后崩溃，
  `started_at` 超过阈值的 `Running` 行被重新认领。

由此两种语义各自成立：

- **at-least-once**（默认）：`max_attempts > 1` + `reclaim_after`
  开启。任务函数要幂等——worker 可能在写完结果前死掉导致重跑。
- **at-most-once**：`max_attempts=1` 且 `reclaim_after=None`。
  每个任务最多执行一次，但 worker 中途崩溃则那次执行静默丢失。
