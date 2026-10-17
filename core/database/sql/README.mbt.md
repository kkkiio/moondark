# Database

Database library, mimicking [Go `database/sql`](https://pkg.go.dev/database/sql).

## Query

```mbt check
///|
async test {
  @async.with_task_group(group => {
    let (db, executor) = @sql.DB::new(MockAnswerDB())
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let rows = db.query("SELECT * FROM answers")
    defer rows.close()
    let answers = []
    while rows.next() is Some(row) {
      answers.push(row)
    }
    debug_inspect(
      answers,
      content=(
        #|[
        #|  {
        #|    columns: <ArrayView: ["question", "answer"]>,
        #|    values: <ArrayView:
        #|      [
        #|        String("Answer to the Ultimate Question of Life, the Universe, and Everything"),
        #|        String("42"),
        #|      ]>,
        #|  },
        #|]
      ),
    )
  })
}
```

## Execute

```mbt check
///|
async test {
  @async.with_task_group(group => {
    let mock = MockAnswerDB()
    let (db, executor) = @sql.DB::new(mock)
    group.spawn_bg(no_wait=true, () => executor.run())
    db.ready()
    defer db.close()
    let result = db.execute("UPDATE answers SET answer = ?", params=["42"])
    debug_inspect(
      (mock.last_prepared, mock.executed, result.rows_affected),
      content=(
        #|("UPDATE answers SET answer = ?", [[String("42")]], Some(1))
      ),
    )
  })
}
```
