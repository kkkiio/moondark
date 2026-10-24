///|
/// Run `f` with a `DB` over the fake `sqltest` driver. The pool
/// executor and readiness dance is identical to a real driver; the
/// connector is returned so tests can inspect recorded statements.
async fn run_db(
  f : async (@database.DB, @databasetest.FakeConnector) -> Unit,
) -> Unit {
  let connector = @databasetest.FakeConnector::new()
  let (db, executor) = connector.open_db()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    f(db, connector)
  })
}

///|
test "TransactionalTaskDef::new rejects an empty retry budget" {
  try {
    let _d : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
      name="t",
      max_attempts=0,
    )
  } catch {
    e => assert_true(e is @tasks.InvalidTask(_))
  } noraise {
    _ => fail("expected InvalidTask")
  }
}

///|
async test "enqueue_on stores a ready row and returns its id" {
  run_db((db, _connector) => {
    let backend = @tasks.DummyBackend::new(now=() => 1000)
    let email : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
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
    assert_eq(stored.status, @tasks.TaskResultStatus::Ready)
    assert_eq(stored.args, Json::object({ "to": "a@b.c" }))
    assert_eq(stored.run_after, Some(2000))
    assert_eq(stored.enqueued_at, 1000)
    assert_eq(stored.started_at, None)
    assert_eq(stored.attempts, 0)
    assert_eq(stored.max_attempts, 3)
    assert_eq(stored.return_value, None)
    assert_eq(stored.errors, [])
    assert_eq(stored.worker_ids, [])
    // a different task name is a miss, not a leak
    let other : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
      name="other",
    )
    assert_true(other.get_result(backend, id) is None)
    assert_true(email.get_result(backend, "missing") is None)
  })
}

///|
async test "enqueue_on rolls back with the caller transaction" {
  run_db((db, connector) => {
    let backend = @tasks.DummyBackend::new()
    let email : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
      name="send_email",
    )
    try
      (
        db.with_transaction(tx => {
          ignore(email.enqueue_on(backend, tx, args=Json::object({})))
          fail("rollback")
        }) : Unit)
    catch {
      _ => ()
    } noraise {
      _ => fail("expected the transaction to propagate the error")
    }
    assert_eq(connector.conns[0].rollback_count, 1)
    assert_eq(connector.conns[0].commit_count, 0)
  })
}

///|
async test "worker runs a claimed task with typed args" {
  run_db((db, _connector) => {
    let backend = @tasks.DummyBackend::new()
    let def : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
      name="echo",
    )
    let id = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args={ "n": 21 })
    })
    let exec = @tasks.TaskExec::from_def(def, func=(ctx, args : Json) => {
      Json::object({ "attempt": ctx.attempt, "got": args })
    })
    let worker = @tasks.Worker::new(store=backend, tasks=[exec], now=() => 5000)
    assert_true(worker.run_once())
    assert_true(!worker.run_once())
    guard def.get_result(backend, id) is Some(stored) else {
      fail("expected the stored result")
    }
    assert_eq(stored.status, @tasks.TaskResultStatus::Successful)
    assert_eq(
      stored.return_value,
      Some(Json::object({ "attempt": 1, "got": { "n": 21 } })),
    )
    assert_eq(stored.attempts, 1)
    assert_eq(stored.started_at, Some(5000))
    assert_eq(stored.finished_at, Some(5000))
    assert_eq(stored.worker_ids, [worker.id])
  })
}

///|
async test "worker reschedules failures and exhausts the attempt budget" {
  run_db((db, _connector) => {
    let backend = @tasks.DummyBackend::new()
    let def : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
      name="flaky",
      max_attempts=2,
    )
    let id = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::object({}))
    })
    let exec = @tasks.TaskExec::from_def(def, func=(_ctx, _args : Json) => {
      fail("boom")
    })
    let mut now = 1000L
    let worker = @tasks.Worker::new(
      store=backend,
      tasks=[exec],
      now=() => now,
      backoff=attempt => attempt.to_int64() * 100,
    )
    // first failure: back to Ready at now + backoff(1)
    assert_true(worker.run_once())
    guard def.get_result(backend, id) is Some(first) else {
      fail("expected the stored result")
    }
    assert_eq(first.status, @tasks.TaskResultStatus::Ready)
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
      fail("expected the stored result")
    }
    assert_eq(second.status, @tasks.TaskResultStatus::Failed)
    assert_eq(second.attempts, 2)
    assert_eq(second.errors.length(), 2)
    assert_eq(second.finished_at, Some(1100))
    assert_eq(second.worker_ids, [worker.id, worker.id])
  })
}

///|
async test "worker skips rows that are not due yet" {
  run_db((db, _connector) => {
    let backend = @tasks.DummyBackend::new()
    let def : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
      name="later",
    )
    let id = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::object({}), run_after=10_000)
    })
    let mut now = 1000L
    let exec = @tasks.TaskExec::from_def(def, func=(_c, a : Json) => a)
    let worker = @tasks.Worker::new(store=backend, tasks=[exec], now=() => now)
    assert_true(!worker.run_once())
    now = 10_000
    assert_true(worker.run_once())
    guard def.get_result(backend, id) is Some(stored) else {
      fail("expected the stored result")
    }
    assert_eq(stored.status, @tasks.TaskResultStatus::Successful)
  })
}

///|
async test "worker reclaims stale running rows only when enabled" {
  run_db((db, _connector) => {
    let backend = @tasks.DummyBackend::new()
    let def : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
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
    assert_eq(claimed.status, @tasks.TaskResultStatus::Running)
    assert_eq(claimed.attempts, 1)
    let exec = @tasks.TaskExec::from_def(def, func=(_c, a : Json) => a)
    // reclaim disabled: the stale row is left alone
    let once = @tasks.Worker::new(
      store=backend,
      tasks=[exec],
      reclaim_after=None,
      now=() => 100_000,
    )
    assert_true(!once.run_once())
    // reclaim enabled: the stale row is claimed again
    let worker = @tasks.Worker::new(
      store=backend,
      tasks=[exec],
      id="w2",
      reclaim_after=Some(60_000),
      now=() => 100_000,
    )
    assert_true(worker.run_once())
    guard def.get_result(backend, id) is Some(stored) else {
      fail("expected the stored result")
    }
    assert_eq(stored.status, @tasks.TaskResultStatus::Successful)
    assert_eq(stored.attempts, 2)
    assert_eq(stored.worker_ids, ["dead", "w2"])
  })
}

///|
async test "worker marks a row with an unknown task name failed" {
  run_db((db, _connector) => {
    let backend = @tasks.DummyBackend::new()
    let def : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
      name="ghost",
    )
    let id = db.with_transaction(tx => {
      def.enqueue_on(backend, tx, args=Json::object({}))
    })
    // no exec registered for "ghost"
    let worker = @tasks.Worker::new(store=backend, tasks=[])
    assert_true(worker.run_once())
    guard def.get_result(backend, id) is Some(stored) else {
      fail("expected the stored result")
    }
    assert_eq(stored.status, @tasks.TaskResultStatus::Failed)
    assert_eq(stored.errors.length(), 1)
    assert_true(stored.errors[0].exception.contains("unknown task"))
  })
}

///|
async test "args that fail to decode fail the attempt" {
  run_db((db, _connector) => {
    let backend = @tasks.DummyBackend::new()
    // producer and worker disagree on the args type — e.g. they were
    // deployed with different versions of the def. Enqueue writes a
    // Json object; the exec expects an Int and fails to decode.
    let producer : @tasks.TransactionalTaskDef[Json] = @tasks.TransactionalTaskDef::new(
      name="typed",
      max_attempts=1,
    )
    let worker_def : @tasks.TransactionalTaskDef[Int32] = @tasks.TransactionalTaskDef::new(
      name="typed",
    )
    let id = db.with_transaction(tx => {
      producer.enqueue_on(backend, tx, args={ "wrong": "shape" })
    })
    let exec = @tasks.TaskExec::from_def(worker_def, func=(_c, a) => Json(a))
    let worker = @tasks.Worker::new(store=backend, tasks=[exec])
    assert_true(worker.run_once())
    guard producer.get_result(backend, id) is Some(stored) else {
      fail("expected the stored result")
    }
    assert_eq(stored.status, @tasks.TaskResultStatus::Failed)
    assert_eq(stored.errors.length(), 1)
  })
}

///|
test "default backoff doubles to a cap" {
  assert_eq(@tasks.default_backoff(1), 1000)
  assert_eq(@tasks.default_backoff(2), 2000)
  assert_eq(@tasks.default_backoff(3), 4000)
  assert_eq(@tasks.default_backoff(10), 512_000)
  assert_eq(@tasks.default_backoff(11), 600_000)
  assert_eq(@tasks.default_backoff(30), 600_000)
}
