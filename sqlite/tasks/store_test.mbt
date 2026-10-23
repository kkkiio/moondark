///|
/// Open a `SqliteTaskBackend` against a fresh per-test database in a
/// temporary directory and run `f` with the pool executor running; the
/// package's `tasks/schema.sql` (which also sets `busy_timeout` on
/// that connection) has already run.
async fn with_backend(
  now~ : () -> Int64 = () => @env.now().reinterpret_as_int64(),
  f : async (@tasks.SqliteTaskBackend, @sql.DB) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let dir = @fs.tmpdir(prefix="moondark-sqlite-tasks")
    let (db, executor) = @sqlite_database.open_db("\{dir}/tasks.db")
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let conn = db.conn()
    defer conn.close()
    conn.execute_script(@fs.read_file("tasks/schema.sql").text())
    let backend = @tasks.SqliteTaskBackend::new(db, now~)
    ignore(db.execute("DELETE FROM task_results"))
    f(backend, db)
  })
}

///|
async test "enqueue stores a ready row that get_result round-trips" {
  with_backend(now=() => 1000, (backend, db) => {
    let email : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="send_email",
      max_attempts=3,
    )
    let id = db.with_transaction(tx => {
      email.enqueue_on(backend, tx, args={ "to": "a@b.c" }, run_after=2000)
    })
    guard email.get_result(backend, id) is Some(stored) else {
      fail("expected the enqueued row")
    }
    assert_eq(stored.id, id)
    assert_eq(stored.task_name, "send_email")
    assert_eq(stored.status, @moondark_tasks.TaskResultStatus::Ready)
    assert_eq(stored.args, Json::object({ "to": "a@b.c" }))
    assert_eq(stored.run_after, Some(2000))
    assert_eq(stored.enqueued_at, 1000)
    assert_eq(stored.started_at, None)
    assert_eq(stored.finished_at, None)
    assert_eq(stored.attempts, 0)
    assert_eq(stored.max_attempts, 3)
    assert_eq(stored.return_value, None)
    assert_eq(stored.errors, [])
    assert_eq(stored.worker_ids, [])
    assert_true(email.get_result(backend, "missing") is None)
  })
}

///|
async test "rolling back the transaction removes the task row" {
  with_backend((backend, db) => {
    let email : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="send_email",
    )
    // the task row commits atomically with the business writes
    let committed = db.with_transaction(tx => {
      email.enqueue_on(backend, tx, args={ "n": 1 })
    })
    assert_true(email.get_result(backend, committed) is Some(_))
    // rolling back removes the task row too — the outbox is atomic
    let mut rolled_id = ""
    try
      (
        db.with_transaction(tx => {
          rolled_id = email.enqueue_on(backend, tx, args={ "n": 2 })
          fail("rollback")
        }) : Unit)
    catch {
      _ => ()
    } noraise {
      _ => fail("expected the transaction to propagate the error")
    }
    assert_true(email.get_result(backend, rolled_id) is None)
  })
}

///|
async test "worker runs a claimed row to successful and persists bookkeeping" {
  with_backend(now=() => 1000, (backend, db) => {
    let def : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="t",
    )
    let id = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args={ "x": 1 })
    })
    let exec = @moondark_tasks.TaskExec::from_def(def, func=(ctx, args) => {
      Json::object({ "attempt": ctx.attempt, "got": args })
    })
    let worker = @moondark_tasks.Worker::new(store=backend, tasks=[exec], now=() => {
      2000
    })
    assert_true(worker.run_once())
    assert_true(!worker.run_once())
    guard def.get_result(backend, id) is Some(stored) else {
      fail("expected the stored result")
    }
    assert_eq(stored.status, @moondark_tasks.TaskResultStatus::Successful)
    assert_eq(
      stored.return_value,
      Some(Json::object({ "attempt": 1, "got": { "x": 1 } })),
    )
    assert_eq(stored.attempts, 1)
    assert_eq(stored.worker_ids, [worker.id])
    assert_eq(stored.started_at, Some(2000))
    assert_eq(stored.finished_at, Some(2000))
    assert_eq(stored.errors, [])
  })
}

///|
async test "worker reschedules failures within the attempt budget" {
  with_backend((backend, db) => {
    let def : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="t",
      max_attempts=2,
    )
    let id = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::object({}))
    })
    let exec = @moondark_tasks.TaskExec::from_def(def, func=(_c, _a) => {
      fail("boom")
    })
    let mut now = 0L
    let worker = @moondark_tasks.Worker::new(
      store=backend,
      tasks=[exec],
      now=() => now,
      backoff=attempt => attempt.to_int64() * 100,
    )
    // first failure: back to Ready at now + backoff(1)
    assert_true(worker.run_once())
    guard def.get_result(backend, id) is Some(stored) else {
      fail("expected the stored result")
    }
    assert_eq(stored.status, @moondark_tasks.TaskResultStatus::Ready)
    assert_eq(stored.run_after, Some(100))
    assert_eq(stored.started_at, None)
    assert_eq(stored.attempts, 1)
    assert_eq(stored.errors.length(), 1)
    assert_true(stored.errors[0].exception.contains("boom"))
    // not runnable again before run_after
    now = 50
    assert_true(!worker.run_once())
    // due: the second attempt exhausts the budget
    now = 100
    assert_true(worker.run_once())
    guard def.get_result(backend, id) is Some(done) else {
      fail("expected the stored result")
    }
    assert_eq(done.status, @moondark_tasks.TaskResultStatus::Failed)
    assert_eq(done.attempts, 2)
    assert_eq(done.errors.length(), 2)
    assert_eq(done.finished_at, Some(100))
    assert_eq(done.worker_ids, [worker.id, worker.id])
  })
}

///|
async test "worker claims due rows in enqueue order" {
  with_backend(now=() => 0, (backend, db) => {
    let def : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="t",
    )
    let first = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args={ "tag": "first" })
    })
    let second = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args={ "tag": "second" })
    })
    let deferred = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args={ "tag": "deferred" }, run_after=10_000)
    })
    let claim = () => backend.claim(worker_id="w", now=1000L, stale_before=None)
    guard claim() is Some(a) else { fail("expected a claim") }
    assert_eq(a.id, first)
    guard claim() is Some(b) else { fail("expected a claim") }
    assert_eq(b.id, second)
    // the deferred row is left, and it is not due yet
    assert_true(claim() is None)
    guard backend.claim(worker_id="w", now=10_000L, stale_before=None)
      is Some(due) else {
      fail("expected the deferred row once due")
    }
    assert_eq(due.id, deferred)
  })
}

///|
async test "worker reclaim policy decides stale running rows" {
  with_backend((backend, db) => {
    let def : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="t",
      max_attempts=3,
    )
    let id = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::object({}))
    })
    // simulate a crashed worker: claimed, then abandoned mid-run
    guard backend.claim(worker_id="dead", now=0L, stale_before=None)
      is Some(claimed) else {
      fail("expected the row to be claimable")
    }
    assert_eq(claimed.status, @moondark_tasks.TaskResultStatus::Running)
    assert_eq(claimed.attempts, 1)
    let exec = @moondark_tasks.TaskExec::from_def(def, func=(_c, a) => a)
    // reclaim disabled: the stale row is left alone
    let once = @moondark_tasks.Worker::new(
      store=backend,
      tasks=[exec],
      reclaim_after=None,
      now=() => 100_000,
    )
    assert_true(!once.run_once())
    // reclaim enabled: the stale row is claimed again
    let worker = @moondark_tasks.Worker::new(
      store=backend,
      tasks=[exec],
      reclaim_after=Some(60_000),
      now=() => 100_000,
    )
    assert_true(worker.run_once())
    guard def.get_result(backend, id) is Some(stored) else {
      fail("expected the stored result")
    }
    assert_eq(stored.status, @moondark_tasks.TaskResultStatus::Successful)
    assert_eq(stored.attempts, 2)
    assert_eq(stored.worker_ids, ["dead", worker.id])
    assert_eq(stored.started_at, Some(100_000))
  })
}

///|
async test "a reclaimed task keeps the newer attempt when an old worker completes" {
  with_backend((backend, db) => {
    let def : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="fenced",
      max_attempts=3,
    )
    let id = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::null())
    })
    let old = backend.claim(worker_id="old", now=0, stale_before=None).unwrap()
    let current = backend
      .claim(worker_id="current", now=100000, stale_before=Some(50000))
      .unwrap()
    backend.save({
      ..old,
      status: Successful,
      return_value: Some(Json("stale")),
    })
    let stored = def.get_result(backend, id).unwrap()
    assert_eq(stored.attempts, 2)
    assert_eq(stored.status, @moondark_tasks.TaskResultStatus::Running)
    assert_eq(stored.worker_ids, ["old", "current"])
    backend.save({
      ..current,
      status: Successful,
      return_value: Some(Json("current")),
    })
    assert_eq(
      def.get_result(backend, id).unwrap().return_value,
      Some(Json("current")),
    )
    backend.save({ ..old, status: Failed, })
    assert_eq(
      def.get_result(backend, id).unwrap().status,
      @moondark_tasks.TaskResultStatus::Successful,
    )
  })
}
