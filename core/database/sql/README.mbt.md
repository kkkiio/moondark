# Database

Database library, mimicking [Go `database/sql`](https://pkg.go.dev/database/sql).

## Query

```mbt check
///|
async test {
  let db = @sql.DB(MockAnswerDB())
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
      #|    columns: ["question", "answer"],
      #|    values: [
      #|      String("Answer to the Ultimate Question of Life, the Universe, and Everything"),
      #|      String("42"),
      #|    ],
      #|  },
      #|]
    ),
  )
}
```

## Execute

```mbt check
///|
async test {
  let mock = MockAnswerDB()
  let db = @sql.DB(mock)
  defer db.close()
  db.execute("UPDATE answers SET answer = ?", params=["42"])
  debug_inspect(
    (mock.last_prepared, mock.executed),
    content=(
      #|("UPDATE answers SET answer = ?", [[String("42")]])
    ),
  )
}
```
