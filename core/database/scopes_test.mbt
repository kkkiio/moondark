///|
async test "cardinality, owned rows and driver independent decoding" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_open=1), db => {
    let row = db.query_one("SELECT question, answer")
    assert_eq((row.get(1) : String), "42")
    assert_eq(row.len(), 2)
    assert_eq(row.index_of("answer"), Some(1))
    assert_eq(row.index_of("absent"), None)
    assert_eq(row.columns().length(), 2)
    assert_eq(row.values().length(), 2)
    connector.conns[0].row_count = 0
    assert_eq(db.query_all("empty").length(), 0)
    assert_true(db.query_opt("empty") is None)
    try ignore(db.query_one("empty")) catch {
      @database.DatabaseError::RowCount(_) => ()
      e => raise e
    } noraise {
      _ => fail("expected RowCount")
    }
    connector.conns[0].row_count = 2
    assert_eq(db.query_all("two").length(), 2)
    try ignore(db.query_opt("two")) catch {
      @database.DatabaseError::RowCount(_) => ()
      e => raise e
    } noraise {
      _ => fail("expected RowCount")
    }
    assert_eq(db.stats().in_use, 0)
    assert_eq((row.get_name("answer") : String), "42")
  })
}

///|
async test "all scoped handles reject escape including synchronous metadata" {
  run_db(@database.DB::create(MockConnector(), max_open=1), db => {
    let conn = db.with_conn(conn => conn)
    try conn.ping() catch {
      @database.DatabaseError::ScopeExpired => ()
      e => raise e
    } noraise {
      _ => fail("expected ScopeExpired")
    }
    let tx = db.with_transaction(tx => tx)
    try tx.commit() catch {
      @database.DatabaseError::ScopeExpired => ()
      e => raise e
    } noraise {
      _ => fail("expected ScopeExpired")
    }
    let stmt = db.with_conn(conn => conn.with_prepared("SELECT", stmt => stmt))
    try ignore(stmt.num_input()) catch {
      @database.DatabaseError::ScopeExpired => ()
      e => raise e
    } noraise {
      _ => fail("expected ScopeExpired")
    }
    try ignore(stmt.query_all()) catch {
      @database.DatabaseError::ScopeExpired => ()
      e => raise e
    } noraise {
      _ => fail("expected ScopeExpired")
    }
    let stream = db.with_stream("SELECT", stream => stream)
    try ignore(stream.columns()) catch {
      @database.DatabaseError::ScopeExpired => ()
      e => raise e
    } noraise {
      _ => fail("expected ScopeExpired")
    }
    try ignore(stream.next()) catch {
      @database.DatabaseError::ScopeExpired => ()
      e => raise e
    } noraise {
      _ => fail("expected ScopeExpired")
    }
    db.ping()
  })
}

///|
async test "early stream exit drains before reuse and finishes idempotently" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_open=1), db => {
    db.with_stream("SELECT", stream => {
      assert_eq(stream.columns().length(), 2)
      assert_true(stream.next() is Some(_))
    })
    assert_eq(connector.stats.rows_closed, 1)
    assert_eq(db.stats().in_use, 0)
    db.with_stream("SELECT", stream => {
      stream.finish()
      stream.finish()
      assert_true(stream.next() is None)
    })
    assert_eq(connector.stats.rows_closed, 2)
    db.ping()
    assert_eq(connector.stats.connect_count, 1)
  })
}

///|
async test "explicit transaction completion is not repeated" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_open=1), db => {
    db.with_transaction(tx => tx.commit())
    assert_eq(connector.stats.commit_count, 1)
    db.with_transaction(tx => tx.rollback())
    assert_eq(connector.stats.commit_count, 1)
    assert_eq(connector.stats.rollback_count, 1)
    db.with_transaction(tx => {
      tx.commit()
      try tx.ping() catch {
        @database.DatabaseError::Closed(_) => ()
        e => raise e
      } noraise {
        _ => fail("expected completed transaction")
      }
    })
    assert_eq(connector.stats.commit_count, 2)
  })
}

///|
async test "cleanup failures preserve the business error and retire the connection" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_open=1), db => {
    connector.stats.fail_cleanup = Some(Failure("cleanup"))
    try
      db.with_transaction(tx => {
        tx.with_prepared("SELECT", stmt => {
          stmt.with_stream(stream => {
            ignore(stream.next())
            (fail("business") : Unit)
          })
        })
      })
    catch {
      Failure(message) => assert_true(message.contains("business"))
      e => raise e
    } noraise {
      _ => fail("expected business error")
    }
    assert_eq(connector.stats.rows_closed, 1)
    assert_eq(connector.stats.statements_closed, 1)
    assert_eq(connector.stats.rollback_count, 1)
    assert_eq(db.stats().in_use, 0)
    connector.stats.fail_cleanup = None
    db.ping()
    assert_eq(connector.stats.connect_count, 2)
  })
}

///|
async test "cancellation drains, closes prepared statements, rolls back and returns capacity" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_open=1), db => {
    let result = @async.with_timeout_opt(10, () => {
      db.with_transaction(tx => {
        tx.with_prepared("SELECT", stmt => {
          stmt.with_stream(stream => {
            ignore(stream.next())
            @async.sleep(100)
          })
        })
      })
    })
    assert_true(result is None)
    assert_eq(connector.stats.rows_closed, 1)
    assert_eq(connector.stats.statements_closed, 1)
    assert_eq(connector.stats.rollback_count, 1)
    assert_eq(connector.stats.commit_count, 0)
    assert_eq(db.stats().in_use, 0)
    db.ping()
    assert_eq(connector.stats.connect_count, 1)
  })
}

///|
async test "statement cache is per connection, least recently used, and optional" {
  let connector = MockConnector()
  run_db(
    @database.DB::create(connector, max_open=1, statement_cache_capacity=2),
    db => {
      ignore(db.execute("a"))
      ignore(db.execute("b"))
      ignore(db.execute("a"))
      ignore(db.execute("c"))
      assert_eq(connector.conns[0].prepare_count, 3)
      assert_eq(connector.stats.statements_closed, 1)
      ignore(db.execute("a"))
      assert_eq(connector.conns[0].prepare_count, 3)
      ignore(db.execute("b"))
      assert_eq(connector.conns[0].prepare_count, 4)
      db.with_conn(conn => {
        conn.with_prepared("a", stmt => {
          ignore(stmt.execute())
          ignore(stmt.execute())
          assert_eq(stmt.num_input(), -1)
        })
      })
      assert_eq(connector.conns[0].prepare_count, 5)
    },
  )
  assert_eq(connector.stats.statements_closed, 5)
  let connector = MockConnector()
  run_db(@database.DB::create(connector, statement_cache_capacity=0), db => {
    ignore(db.execute("a"))
    ignore(db.execute("a"))
    assert_eq(connector.conns[0].prepare_count, 2)
    assert_eq(connector.stats.statements_closed, 2)
  })
}

///|
async test "parameter arity is checked and GenericClient uses completion methods" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector), db => {
    db.ping()
    connector.conns[0].arity = 1
    let client : &@database.GenericClient = db
    try ignore(client.execute("a")) catch {
      @database.DatabaseError::ArityMismatch(expected=1, actual=0) => ()
      e => raise e
    } noraise {
      _ => fail("expected ArityMismatch")
    }
    ignore(client.query_one("a", params=[1]))
    db.with_transaction(tx => {
      let client : &@database.GenericClient = tx
      ignore(client.query_opt("a", params=[1]))
    })
  })
}

///|
async test "transaction startup retries BadConn but never replays the callback" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_open=1), db => {
    db.ping()
    connector.conns[0].fail_begin = Some(
      @driver.BadConn(Failure("before begin")),
    )
    let mut calls = 0
    db.with_transaction(_ => calls += 1)
    assert_eq(calls, 1)
    assert_eq(connector.stats.connect_count, 2)
    try
      db.with_transaction(_ => {
        calls += 1
        (
          {
            raise @driver.BadConn(Failure("callback"))
          } : Unit)
      })
    catch {
      @driver.BadConn(_) => ()
      e => raise e
    } noraise {
      _ => fail("expected BadConn")
    }
    assert_eq(calls, 2)
  })
}

///|
async test "explicit completion drains an unread transaction stream" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_open=1), db => {
    db.with_transaction(tx => tx.with_stream("SELECT", _ => tx.commit()))
    assert_eq(connector.stats.rows_closed, 1)
    assert_eq(connector.stats.commit_count, 1)
    db.with_transaction(tx => {
      tx.with_prepared("SELECT", stmt => stmt.with_stream(_ => tx.rollback()))
    })
    assert_eq(connector.stats.rows_closed, 2)
    assert_eq(connector.stats.rollback_count, 1)
    db.ping()
    assert_eq(connector.stats.connect_count, 1)
  })
}

///|
async test "BadConn during cleanup never replays a completed write" {
  let connector = MockConnector()
  run_db(
    @database.DB::create(connector, max_open=1, statement_cache_capacity=0),
    db => {
      connector.stats.fail_cleanup = Some(@driver.BadConn(Failure("close")))
      try ignore(db.execute("INSERT")) catch {
        @driver.BadConn(_) => ()
        e => raise e
      } noraise {
        _ => fail("expected close failure")
      }
      assert_eq(connector.stats.exec_count, 1)
      assert_eq(connector.stats.connect_count, 1)
      connector.stats.fail_cleanup = None
      db.ping()
    },
  )
}

///|
async test "BadConn after a query starts never replays RETURNING statements" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_open=1), db => {
    connector.stats.next_error = Some(@driver.BadConn(Failure("next")))
    try ignore(db.query_one("INSERT RETURNING")) catch {
      @driver.BadConn(_) => ()
      e => raise e
    } noraise {
      _ => fail("expected row failure")
    }
    assert_eq(connector.stats.connect_count, 1)
    assert_eq(connector.stats.rows_closed, 1)
    connector.stats.next_error = None
    db.ping()
  })
}

///|
async test "cancelled connection creation cannot strand pool capacity" {
  let connector = MockConnector()
  connector.connect_delay = 20
  run_db(@database.DB::create(connector, max_open=1), db => {
    assert_true(@async.with_timeout_opt(5, () => db.ping()) is None)
    @async.with_timeout(200, () => db.ping())
    assert_eq(db.stats().in_use, 0)
    assert_eq(db.stats().idle, 1)
    assert_eq(connector.stats.connect_count, 2)
    assert_eq(connector.stats.close_count, 1)
  })
}

///|
async test "closing the pool waits for checked out scopes and wakes queued acquisitions" {
  let connector = MockConnector()
  let (db, executor) = @database.DB::create(connector, max_open=1)
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    let connection = group.spawn(() => db.with_conn(_ => @async.sleep(30)))
    @async.sleep(5)
    let waiter = group.spawn(() => {
      try db.ping() catch {
        @database.DatabaseError::Closed(_) => ()
        e => raise e
      } noraise {
        _ => fail("expected closed pool")
      }
    })
    @async.sleep(5)
    db.close()
    connection.wait()
    waiter.wait()
    assert_eq(connector.stats.close_count, 1)
    assert_eq(db.stats().in_use, 0)
    assert_eq(db.stats().open, 0)
    db.close()
  })
}

///|
async test "cached statements belong to their physical connection" {
  let connector = MockConnector()
  run_db(@database.DB::create(connector, max_open=2), db => {
    db.with_conn(conn => {
      ignore(conn.execute("a"))
      ignore(db.execute("a"))
      ignore(db.execute("a"))
      ignore(conn.execute("a"))
      assert_eq(connector.stats.connect_count, 2)
      assert_eq(connector.conns[0].prepare_count, 1)
      assert_eq(connector.conns[1].prepare_count, 1)
    })
  })
}

///|
async test "finished streams allow another operation before their callback returns" {
  for capacity in [0, 1, 100] {
    let connector = MockConnector()
    run_db(
      @database.DB::create(
        connector,
        max_open=1,
        statement_cache_capacity=capacity,
      ),
      db => {
        let result = @async.with_timeout_opt(1000, () => {
          db.with_conn(conn => {
            conn.with_stream("SELECT", stream => {
              stream.finish()
              conn.ping()
              ignore(conn.execute("different statement"))
              assert_true(stream.next() is None)
            })
            conn.with_stream("SELECT", stream => {
              ignore(stream.collect())
              conn.ping()
            })
            conn.with_prepared("SELECT", stmt => {
              stmt.with_stream(stream => {
                stream.finish()
                ignore(stmt.execute())
                ignore(stmt.query_one())
                conn.ping()
              })
            })
          })
          db.with_transaction(tx => {
            tx.with_stream("SELECT", stream => {
              stream.finish()
              tx.ping()
              ignore(tx.execute("different statement"))
            })
            tx.with_prepared("SELECT", stmt => {
              stmt.with_stream(stream => {
                stream.finish()
                ignore(stmt.execute())
                tx.ping()
              })
            })
          })
        })
        assert_true(
          result is Some(_),
          msg="finished stream retained operation gate",
        )
        assert_eq(db.stats().in_use, 0)
        db.ping()
      },
    )
  }
}
