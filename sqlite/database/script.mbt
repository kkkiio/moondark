///|
/// Split `script` into individual statements on `;` boundaries,
/// following SQLite's lexical rules — a port of the state machine in
/// `sqlite3_complete()`:
///
/// - `'…'`, `"…"`, `` `…` `` quote with doubled-quote escapes only
///   (SQLite has no backslash escapes); `[…]` quotes identifiers.
/// - `--` line comments and non-nesting `/* */` block comments; a
///   chunk holding only comments and whitespace is dropped.
/// - `CREATE [TEMP|TEMPORARY] TRIGGER … BEGIN …; END;` is one
///   statement: inside a trigger only `; END ;` terminates it.
///
/// Temporary: the sqlite3 bindings reject multi-statement input to
/// `prepare_async` and expose neither the prepare tail nor
/// `sqlite3_exec`, either of which would let SQLite split for us.
fn split_script(script : String) -> Array[String] {
  let s = script
  let n = s.length()
  let statements : Array[String] = []
  let mut chunk_start = 0
  let mut state = SplitState::Start
  let mut i = 0
  while i < n {
    let c = s[i]
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{0C}' {
      i += 1
      continue
    }
    if c == '-' && i + 1 < n && s[i + 1] == '-' {
      while i < n && s[i] != '\n' {
        i += 1
      }
      continue
    }
    if c == '/' && i + 1 < n && s[i + 1] == '*' {
      i += 2
      while i < n && !(s[i] == '*' && i + 1 < n && s[i + 1] == '/') {
        i += 1
      }
      i = if i < n { i + 2 } else { n }
      continue
    }
    if c == ';' {
      match state {
        Start => chunk_start = i + 1
        Trigger | Semi => state = Semi
        Normal | Explain | Create | End => {
          statements.push(s[chunk_start:i].to_owned())
          chunk_start = i + 1
          state = Start
        }
      }
      i += 1
      continue
    }
    let token_start = i
    let is_word = c == '_' ||
      c == '$' ||
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c.to_int() >= 0x80
    if c == '\'' || c == '"' || c == '`' || c == '[' {
      let close : UInt16 = if c == '[' { ']' } else { c }
      i += 1
      while i < n {
        if s[i] == close && !(c != '[' && i + 1 < n && s[i + 1] == close) {
          break
        }
        i += if s[i] == close { 2 } else { 1 }
      }
      i = if i < n { i + 1 } else { n }
    } else if is_word {
      while i < n &&
            (
              s[i] == '_' ||
              s[i] == '$' ||
              (s[i] >= 'a' && s[i] <= 'z') ||
              (s[i] >= 'A' && s[i] <= 'Z') ||
              (s[i] >= '0' && s[i] <= '9') ||
              s[i].to_int() >= 0x80
            ) {
        i += 1
      }
    } else {
      i += 1
    }
    let word = if is_word { s[token_start:i].to_owned().to_upper() } else { "" }
    state = match (state, word) {
      (Start, "EXPLAIN") => Explain
      (Start | Explain, "CREATE") => Create
      (Create, "TEMP" | "TEMPORARY") => Create
      (Create, "TRIGGER") => Trigger
      (Semi, "END") => End
      (Start | Explain | Create | Normal, _) => Normal
      (Trigger | Semi | End, _) => Trigger
    }
  }
  if state != Start {
    statements.push(s[chunk_start:n].to_owned())
  }
  statements
}

///|
/// States of `split_script`, mirroring `sqlite3_complete()`.
priv enum SplitState {
  /// Between statements: nothing but whitespace and comments so far.
  Start
  /// Inside an ordinary statement ended by a single `;`.
  Normal
  /// `EXPLAIN` seen at the start of a statement.
  Explain
  /// `CREATE` (optionally `TEMP`/`TEMPORARY`) seen at the start.
  Create
  /// Inside a trigger body, which only `; END ;` terminates.
  Trigger
  /// The `;` of a trigger's closing `; END ;`.
  Semi
  /// The `; END` of a trigger's closing `; END ;`.
  End
} derive(Eq)
