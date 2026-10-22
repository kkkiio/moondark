# tasks

Transactional background task queue and worker backed by `database/sql`.

## Quick Start

```mbt check
///|
async test {
  let email : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
    name="send_email",
    max_attempts=3,
  )
  let backend = @tasks.DummyBackend::new()
  let (db, executor) = @sqltest.FakeConnector::new().open_db()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    // Enqueue inside the caller's database transaction
    let id = db.with_transaction(tx => {
      email.enqueue_on(backend, tx, args={ "to": "user@example.com" })
    })
    let worker = @tasks.Worker::new(store=backend, tasks=[
      @tasks.TaskExec::from_def(email, func=(_ctx, args) => {
        Json::object({ "sent": args })
      }),
    ])
    assert_true(worker.run_once())
    assert_true(
      email.get_result(backend, id) is Some({ status: Successful, .. }),
    )
  })
}
```
