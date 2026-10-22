# moondark_sqlite/tasks

SQLite backend for `xziheng/moondark/tasks`, storing enqueued tasks and execution results in a SQLite table.

## Quick Start

Apply [`schema.sql`](./schema.sql) to create the `task_results` table and index, then enqueue tasks and run a worker:

```mbt nocheck
///|
async test {
  @async.with_task_group(group => {
    let (db, executor) = @sqlite_database.open_db("app.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()

    let backend = @sqlite_tasks.SqliteTaskBackend::new(db)
    let email : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="send_email",
    )
    let _id = db.with_transaction(tx => {
      email.enqueue_on(backend, tx, args={ "to": "user@example.com" })
    })

    let worker = @moondark_tasks.Worker::new(store=backend, tasks=[
      @moondark_tasks.TaskExec::from_def(email, func=(_ctx, args) => args),
    ])
    group.spawn_bg(no_wait=true, () => worker.run())
  })
}
```
