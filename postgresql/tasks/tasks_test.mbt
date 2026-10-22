///|
/// Apply the package's `tasks/schema.sql` on a pooled connection.
async fn apply_schema(db : @sql.DB) -> Unit {
  let conn = db.conn()
  defer conn.close()
  conn.execute_script(@fs.read_file("tasks/schema.sql").text())
}

///|
/// Start a throwaway postgres container, open a `DB` against it, apply
/// the package's schema and run `f` with the pool executor running.
/// Both the pool and the container are cleaned up when `f` returns.
async fn run_db(f : async (@sql.DB) -> Unit, max_open~ : Int32 = 10) -> Unit {
  let pg = @postgres.run()
  defer pg.cleanup()
  let dsn = pg.connection_string(ssl_mode="disable")
  @async.with_task_group(group => {
    let (db, executor) = @postgresql_database.open_db(dsn, max_open~)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    apply_schema(db)
    f(db)
  })
}

///|
async test "enqueue stores a ready result and get_result reads it back" {
  run_db(db => {
    let backend = @tasks.PostgresTaskBackend::new(db, now=() => 1000)
    // applying the schema is idempotent
    apply_schema(db)
    let email : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="send_email",
      max_attempts=3,
    )
    let id = db.with_transaction(tx => {
      email.enqueue_on(backend, tx, args={ "to": "a@b.c" }, run_after=9_000)
    })
    guard email.get_result(backend, id) is Some(stored) else {
      fail("expected a stored result")
    }
    assert_eq(stored.id, id)
    assert_eq(stored.task_name, "send_email")
    assert_eq(stored.status, @moondark_tasks.TaskResultStatus::Ready)
    assert_eq(stored.args, Json::object({ "to": "a@b.c" }))
    assert_eq(stored.run_after, Some(9_000))
    assert_eq(stored.enqueued_at, 1000)
    assert_eq(stored.started_at, None)
    assert_eq(stored.finished_at, None)
    assert_eq(stored.attempts, 0)
    assert_eq(stored.max_attempts, 3)
    assert_eq(stored.return_value, None)
    assert_true(stored.errors.is_empty())
    assert_true(stored.worker_ids.is_empty())
    assert_true(email.get_result(backend, "missing") is None)
  })
}

///|
async test "enqueue commits and rolls back with the transaction" {
  run_db(db => {
    let backend = @tasks.PostgresTaskBackend::new(db)
    let def : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="t",
    )
    // committed: the task row is visible once with_transaction returns
    let committed = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args={ "k": 1 })
    })
    guard def.get_result(backend, committed) is Some(stored) else {
      fail("expected the committed task row")
    }
    assert_eq(stored.status, @moondark_tasks.TaskResultStatus::Ready)
    // rolled back: the outbox row disappears with the business writes
    let mut rolled_back = ""
    try
      (
        db.with_transaction(tx => {
          rolled_back = def.enqueue_on(backend, tx, args={ "k": 2 })
          fail("rollback")
        }) : Unit)
    catch {
      _ => ()
    } noraise {
      _ => fail("expected the transaction to propagate the error")
    }
    assert_true(def.get_result(backend, rolled_back) is None)
  })
}

///|
async test "worker runs a claimed task and persists the return value" {
  run_db(db => {
    let backend = @tasks.PostgresTaskBackend::new(db, now=() => 1000)
    let def : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="echo",
    )
    let id = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args={ "n": 21 })
    })
    let exec = @moondark_tasks.TaskExec::from_def(def, func=(_c, a) => a)
    let worker = @moondark_tasks.Worker::new(
      store=backend,
      tasks=[exec],
      id="worker-1",
      now=() => 2000,
    )
    assert_true(worker.run_once())
    // the queue is drained
    assert_true(!worker.run_once())
    guard def.get_result(backend, id) is Some(stored) else {
      fail("expected a stored result")
    }
    assert_eq(stored.status, @moondark_tasks.TaskResultStatus::Successful)
    assert_eq(stored.return_value, Some(Json::object({ "n": 21 })))
    assert_eq(stored.attempts, 1)
    assert_eq(stored.started_at, Some(2000))
    assert_eq(stored.finished_at, Some(2000))
    assert_eq(stored.worker_ids, ["worker-1"])
    assert_eq(stored.errors.length(), 0)
  })
}

///|
async test "worker reschedules failures and exhausts the attempt budget" {
  run_db(db => {
    let backend = @tasks.PostgresTaskBackend::new(db, now=() => 100)
    let def : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="flaky",
      max_attempts=2,
    )
    let id = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::object({}))
    })
    let exec = @moondark_tasks.TaskExec::from_def(def, func=(_c, _a) => {
      fail("boom")
    })
    let mut now = 1000L
    let worker = @moondark_tasks.Worker::new(
      store=backend,
      tasks=[exec],
      id="w1",
      backoff=attempt => attempt.to_int64() * 100,
      reclaim_after=None,
      now=() => now,
    )
    assert_true(worker.run_once())
    guard def.get_result(backend, id) is Some(first) else {
      fail("expected a stored result")
    }
    // first failure: back to ready with run_after = now + backoff(1)
    assert_eq(first.status, @moondark_tasks.TaskResultStatus::Ready)
    assert_eq(first.run_after, Some(1100))
    assert_eq(first.started_at, None)
    assert_eq(first.attempts, 1)
    assert_eq(first.errors.length(), 1)
    assert_true(first.errors[0].exception.contains("boom"))
    // not runnable before run_after
    now = 1050
    assert_true(!worker.run_once())
    // due: the second attempt exhausts the budget
    now = 1100
    assert_true(worker.run_once())
    guard def.get_result(backend, id) is Some(second) else {
      fail("expected a stored result")
    }
    assert_eq(second.status, @moondark_tasks.TaskResultStatus::Failed)
    assert_eq(second.attempts, 2)
    assert_eq(second.errors.length(), 2)
    assert_eq(second.finished_at, Some(1100))
    assert_eq(second.worker_ids, ["w1", "w1"])
  })
}

///|
async test "worker reclaims stale running rows only when enabled" {
  run_db(db => {
    let backend = @tasks.PostgresTaskBackend::new(db, now=() => 0)
    let def : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="t",
      max_attempts=3,
    )
    let id = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::object({}))
    })
    // a crashed worker claimed the row long ago and never saved
    guard backend.claim(worker_id="dead", now=0L, stale_before=None) is Some(_) else {
      fail("expected the first claim to succeed")
    }
    let exec = @moondark_tasks.TaskExec::from_def(def, func=(_c, a) => a)
    // reclaim disabled: the stale row is left alone
    let once = @moondark_tasks.Worker::new(
      store=backend,
      tasks=[exec],
      reclaim_after=None,
      now=() => 100,
    )
    assert_true(!once.run_once())
    // reclaim enabled: the stale row is claimed again and runs to success
    let worker = @moondark_tasks.Worker::new(
      store=backend,
      tasks=[exec],
      id="worker-2",
      reclaim_after=Some(60),
      now=() => 100,
    )
    assert_true(worker.run_once())
    guard def.get_result(backend, id) is Some(stored) else {
      fail("expected a stored result")
    }
    assert_eq(stored.status, @moondark_tasks.TaskResultStatus::Successful)
    assert_eq(stored.attempts, 2)
    assert_eq(stored.worker_ids, ["dead", "worker-2"])
    // a running row out of attempts is never reclaimed
    let single : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="u",
      max_attempts=1,
    )
    let spent = db.with_transaction(tx => {
      single.enqueue_on(backend, tx, args=Json::object({}))
    })
    ignore(backend.claim(worker_id="dead", now=0L, stale_before=None))
    assert_true(
      backend.claim(worker_id="w", now=1_000_000L, stale_before=Some(0)) is None,
    )
    guard single.get_result(backend, spent) is Some(running) else {
      fail("expected a stored result")
    }
    assert_eq(running.status, @moondark_tasks.TaskResultStatus::Running)
  })
}

///|
async test "claim picks due rows in enqueue order" {
  run_db(db => {
    let mut clock = 0L
    let backend = @tasks.PostgresTaskBackend::new(db, now=() => {
      clock += 1
      clock
    })
    let def : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="t",
    )
    let first = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::object({}))
    })
    let second = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::object({}))
    })
    let deferred = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::object({}), run_after=10_000)
    })
    let claim = () => backend.claim(worker_id="w", now=1000L, stale_before=None)
    guard claim() is Some(a) else { fail("expected a claim") }
    assert_eq(a.id, first)
    guard claim() is Some(b) else { fail("expected a claim") }
    assert_eq(b.id, second)
    // only the deferred row is left, and it is not due yet
    assert_true(claim() is None)
    guard backend.claim(worker_id="w", now=10_000L, stale_before=None)
      is Some(due) else {
      fail("expected the deferred row once due")
    }
    assert_eq(due.id, deferred)
    // attempts and worker_ids bookkeeping on a claimed row
    guard def.get_result(backend, first) is Some(claimed) else {
      fail("expected a stored result")
    }
    assert_eq(claimed.status, @moondark_tasks.TaskResultStatus::Running)
    assert_eq(claimed.attempts, 1)
    assert_eq(claimed.worker_ids, ["w"])
    assert_eq(claimed.started_at, Some(1000))
  })
}

///|
async test "concurrent claims never pick the same row" {
  run_db(max_open=4, db => {
    let backend = @tasks.PostgresTaskBackend::new(db)
    let def : @moondark_tasks.TransactionalTaskDef[Json] = @moondark_tasks.TransactionalTaskDef::new(
      name="t",
    )
    db.with_transaction(tx => {
      ignore(def.enqueue_on(backend, tx, args=Json::object({})))
      ignore(def.enqueue_on(backend, tx, args=Json::object({})))
    })
    let claims : Array[async () -> @moondark_tasks.TaskResult?] = [
      () => backend.claim(worker_id="w1", now=1000L, stale_before=None),
      () => backend.claim(worker_id="w2", now=1000L, stale_before=None),
      () => backend.claim(worker_id="w3", now=1000L, stale_before=None),
    ]
    let results = @async.all(claims, max_concurrent=3)
    let ids : Array[String] = []
    for result in results {
      match result {
        Some(claimed) => ids.push(claimed.id)
        None => ()
      }
    }
    // two rows, three workers: two distinct claims and one empty hand
    assert_eq(ids.length(), 2)
    assert_true(ids[0] != ids[1])
    // two run_once calls likewise never run the same task twice
    let exec = @moondark_tasks.TaskExec::from_def(def, func=(_c, a) => a)
    let first = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::object({}))
    })
    let second = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::object({}))
    })
    let w1 = @moondark_tasks.Worker::new(
      store=backend,
      tasks=[exec],
      id="w1",
      reclaim_after=None,
      now=() => 2000,
    )
    let w2 = @moondark_tasks.Worker::new(
      store=backend,
      tasks=[exec],
      id="w2",
      reclaim_after=None,
      now=() => 2000,
    )
    let ran = @async.all(
      [() => w1.run_once(), () => w2.run_once()],
      max_concurrent=2,
    )
    assert_eq(ran, [true, true])
    guard def.get_result(backend, first) is Some(one) &&
      def.get_result(backend, second) is Some(two) else {
      fail("expected stored results")
    }
    assert_eq(one.status, @moondark_tasks.TaskResultStatus::Successful)
    assert_eq(two.status, @moondark_tasks.TaskResultStatus::Successful)
    // each row carries exactly the id of the worker that claimed it
    assert_true(one.worker_ids != two.worker_ids)
  })
}
