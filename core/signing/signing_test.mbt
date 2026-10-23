///|
/// `f` 抛出 SignError::BadSignature 时返回 true。
fn[T] is_bad_signature(f : () -> T raise @signing.SignError) -> Bool {
  try {
    ignore(f())
    false
  } catch {
    @signing.BadSignature => true
    _ => false
  }
}

///|
/// `f` 抛出 SignError::SignatureExpired 时返回 true。
fn[T] is_expired(f : () -> T raise @signing.SignError) -> Bool {
  try {
    ignore(f())
    false
  } catch {
    @signing.SignatureExpired => true
    _ => false
  }
}

///|
/// Django 5.x 实测向量：
/// `TimestampSigner(key="test-secret-key", salt="repage-job").signature("abc:1Z9")`
/// 其中 b62_decode("1Z9") == 6023（秒）；`now` 注入毫秒，嵌入时换算为秒，
/// 固定时钟下 sign 应与 Django 逐字节一致。
test "sign matches django 5.x wire format" {
  let signer = @signing.Signer(key="test-secret-key", salt="repage-job", now=() => {
    6_023_000UL
  })
  assert_eq(
    signer.sign("abc"),
    "abc:1Z9:8RBy1UZK-PIH7MfXblAwwa6qpz6rfgM4mdonLsTGTrQ",
  )
}

///|
/// Django `signing.dumps({"j":1,"a":2,"k":"input"}, key="test-secret-key",
/// salt="repage-job")` 的真实产出；loads 不设 max_age 时可永久校验。
test "loads accepts a signature produced by django" {
  let signed = "eyJqIjoxLCJhIjoyLCJrIjoiaW5wdXQifQ:1xJ8dP:AxTpPz6RHoPuYNtylz_L-3UIK3i6JI_owyBqJFXzjU4"
  let loaded = @signing.loads(signed, key="test-secret-key", salt="repage-job")
  assert_eq(loaded.stringify(), "{\"j\":1,\"a\":2,\"k\":\"input\"}")
}

///|
/// dumps 的载荷段必须与 Django `sign_object` 的 base64 一致
/// （紧凑 JSON、key 保序），否则跨实现互验会失败。
test "dumps payload matches django serialization" {
  let signed = @signing.dumps(
    ({ "j": 1, "a": 2, "k": "input" } : Json),
    key="test-secret-key",
    salt="repage-job",
  )
  assert_true(signed.has_prefix("eyJqIjoxLCJhIjoyLCJrIjoiaW5wdXQifQ:"))
}

///|
test "dumps/loads roundtrip" {
  let obj : Json = { "j": 42, "a": 3, "k": "input", "nested": [true, "x"] }
  let signed = @signing.dumps(obj, key="k", salt="s")
  assert_eq(
    @signing.loads(signed, key="k", salt="s").stringify(),
    obj.stringify(),
  )
}

///|
test "sign/unsign roundtrip tolerates separators in value" {
  let signer = @signing.Signer(key="k", salt="s", now=() => 1000UL)
  let signed = signer.sign("a:b:c")
  assert_eq(signer.unsign(signed), "a:b:c")
}

///|
test "unsign rejects malformed or tampered input" {
  let signer = @signing.Signer(key="k", salt="s", now=() => 1000UL)
  let signed = signer.sign("abc")
  // 无分隔符
  assert_true(is_bad_signature(() => signer.unsign("abc")))
  // 签名被篡改
  assert_true(is_bad_signature(() => signer.unsign("\{signed}x")))
  // 签名段不是合法 base64
  assert_true(is_bad_signature(() => signer.unsign("abc:1Z9:%%%")))
  // 载荷被篡改后签名不匹配
  assert_true(
    is_bad_signature(() => signer.unsign(signed.replace(old="abc", new="abd"))),
  )
}

///|
test "unsign rejects wrong key or salt" {
  let signer = @signing.Signer(key="k", salt="s", now=() => 1000UL)
  let signed = signer.sign("abc")
  assert_true(
    is_bad_signature(() => {
      @signing.Signer(key="other", salt="s", now=() => 1000UL).unsign(signed)
    }),
  )
  assert_true(
    is_bad_signature(() => {
      @signing.Signer(key="k", salt="other", now=() => 1000UL).unsign(signed)
    }),
  )
}

///|
test "unsign enforces max_age and its boundary" {
  // sign 于 now=1_000_000ms → wire ts=1000s
  let signed = @signing.Signer(key="k", salt="s", now=() => 1_000_000UL).sign(
    "abc",
  )
  // unsign 于 1_100_000ms → age=100_000ms（验签时钟取整到秒）
  let signer = @signing.Signer(key="k", salt="s", now=() => 1_100_000UL)
  // age == max_age 仍然有效（Django 是 > 判断）
  assert_eq(signer.unsign(signed, max_age=100_000), "abc")
  assert_true(is_expired(() => signer.unsign(signed, max_age=99_999)))
  // max_age 为负必定过期，与 Django max_age=-1 一致
  assert_true(is_expired(() => signer.unsign(signed, max_age=-1)))
}

///|
test "a token signed mid-second is not born old" {
  // wire ts 只到秒：1_000_999ms 签出仍是 ts=1000s，验签时钟同样取整，
  // 同一秒内 age=0，max_age=0 也不能算过期。
  let signer = @signing.Signer(key="k", salt="s", now=() => 1_000_999UL)
  let signed = signer.sign("abc")
  assert_eq(signer.unsign(signed, max_age=0), "abc")
}

///|
test "loads rejects damaged payloads" {
  let signer = @signing.Signer(key="k", salt="s", now=() => 1000UL)
  // 签名合法但载荷不是 base64
  assert_true(is_bad_signature(() => signer.loads(signer.sign("%%%"))))
  // 载荷是 base64 但不是 json（"bm90LWpzb24" = b64url("not-json")）
  assert_true(is_bad_signature(() => signer.loads(signer.sign("bm90LWpzb24"))))
}
