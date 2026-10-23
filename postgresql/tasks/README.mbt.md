# moondark_postgresql/tasks

PostgreSQL backend for `KKKIIO/moondark/tasks`, storing enqueued tasks and execution results in a PostgreSQL table.

## Quick Start

Apply [`schema.sql`](./schema.sql) to create the `task_results` table and index, then enqueue tasks and run a worker:

```mbt nocheck
///|
async test {
  @async.with_task_group(group => {
    let (db, executor) = @postgresql_database.open_db(
      "postgres://user:pass@localhost:5432/app?sslmode=disable",
    )
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()

    let backend = @postgresql_tasks.PostgresTaskBackend::new(db)
    let email : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="send_email",
    )
    let _id = db.with_transaction(tx => {
      email.enqueue_on(backend, tx, args={ "to": "user@example.com" })
    })

    let worker = @moondark_tasks.Worker::new(
      store=backend,
      tasks=[
        @moondark_tasks.TaskExec::from_def(email, func=(_ctx, args) => args),
      ],
      reclaim_after=Some(300_000),
    )
    group.spawn_bg(no_wait=true, () => worker.run())
  })
}
```
