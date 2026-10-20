///|
/// 签名合法但缺少时间戳段（对应 Django Signer.sign 而非
/// TimestampSigner.sign 的产出）也应是 BadSignature。
test "unsign rejects a value without timestamp segment" {
  let signer = Signer(key="k", salt="s", now=() => 1000UL)
  let signed = "only:\{b64_encode(signer.signature_bytes("only").unsafe_reinterpret_as_bytes())}"
  try {
    ignore(signer.unsign(signed))
    fail("expected BadSignature")
  } catch {
    BadSignature => ()
    e => raise e
  }
}

///|
test "base62 roundtrip and alphabet order" {
  assert_eq(b62_encode(0), "0")
  assert_eq(b62_encode(6023), "1Z9")
  // UInt64 最大值的编码（2^64-1 -> "LygHa16AHYF"）
  assert_eq(b62_encode(0xffffffffffffffffUL), "LygHa16AHYF")
  assert_eq(b62_decode("1Z9"), 6023)
  // Int64 上限可以解码（"AzL8n0Y58m7" = 2^63-1）
  assert_eq(b62_decode("AzL8n0Y58m7"), 0x7fffffffffffffffL)
  for input in ["", "not!b62", "AzL8n0Y58m8"] {
    // 空串、非法字符、超 Int64（"AzL8n0Y58m8" = 2^63）都拒绝
    try {
      ignore(b62_decode(input))
      fail("expected BadSignature")
    } catch {
      BadSignature => ()
      e => raise e
    }
  }
}
