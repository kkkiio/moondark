# tasks

Transactional background task queue and worker backed by `database`.

## Quick Start

```mbt check
///|
async test {
  let email : @tasks.Task[Json] = @tasks.Task::new(
    name="send_email",
    max_attempts=3,
  )
  let backend = @tasks.DummyBackend::new()
  let (db, executor) = @databasetest.FakeConnector::new().open_db()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    // Enqueue inside the caller's database transaction
    let id = db.with_transaction(tx => {
      email.enqueue(backend, tx, args={ "to": "user@example.com" })
    })
    let worker = @tasks.Worker::new(store=backend, tasks=[
      email.bind((_ctx, args) => Json::object({ "sent": args })),
    ])
    assert_true(worker.run_once())
    assert_true(
      email.get_result(backend, id) is Some({ status: Successful, .. }),
    )
  })
}
```
