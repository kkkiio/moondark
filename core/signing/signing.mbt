///|
/// `unsign`/`loads` 校验失败时抛出的错误，对应 Django 的
/// `signing.BadSignature` 与 `signing.SignatureExpired`。
/// Django 中 SignatureExpired 继承自 BadSignature，这里两者平级，
/// match 时需要分别处理。
pub(all) suberror SignError {
  /// 签名缺失、被篡改，或 key/salt 不匹配
  BadSignature
  /// 签名有效但超过了 `max_age`（毫秒）
  SignatureExpired
} derive(Debug)

///|
pub extend SignError with Debug::{to_repr}

///|
/// 可复用的 HMAC-SHA256 时间戳签名器，对应
/// `django.core.signing.TimestampSigner`。
///
/// 线格式 `value:ts:sig` 与 Django 5.x 完全兼容，同一 (key, salt) 下
/// 两边产出的串可以互相校验：
/// - `ts` 是 base62 编码的 unix 秒
/// - `sig = base64url(HMAC-SHA256(SHA256(salt + "signer" + key), value:ts))`
///   （url-safe 且去掉 `=` padding）
pub struct Signer {
  priv key_salt : Bytes // utf8(salt + "signer")，派生 HMAC 密钥用
  priv key : Bytes // utf8(secret key)
  priv now : () -> UInt64 // 当前 unix 毫秒；测试可注入固定时钟
}

///|
/// 创建签名器。
///
/// `salt` 把同一个 secret 隔离到不同用途（如 repage 的 "repage-job"），
/// 跨用途的签名互相无效；默认值对应 Django `dumps`/`loads` 的默认 salt。
/// `now` 默认取系统时钟，测试可注入固定值。
pub fn Signer::Signer(
  key~ : String,
  salt~ : String = "KKKIIO.moondark.signing",
  now~ : () -> UInt64 = () => @env.now(),
) -> Signer {
  Signer::{
    key_salt: @utf8.encode("\{salt}signer"),
    key: @utf8.encode(key),
    now,
  }
}

///|
/// 给 `value` 追加当前时间戳与签名，返回 `value:ts:sig`。
/// `value` 里允许出现 ':'——unsign 固定从末尾按段数切分。
/// `now` 以毫秒提供，嵌入 wire 的 `ts` 换算为秒以保持 Django 兼容。
pub fn Signer::sign(self : Signer, value : String) -> String {
  let stamped = "\{value}:\{b62_encode((self.now)() / 1000)}"
  "\{stamped}:\{b64_encode(self.signature_bytes(stamped).unsafe_reinterpret_as_bytes())}"
}

///|
/// 校验并还原 `sign` 的原始值。
/// 签名缺失或不匹配抛 `BadSignature`；
/// `age > max_age`（毫秒）时抛 `SignatureExpired`，默认永不超时
/// （`age == max_age` 仍算有效、未来时间戳必定过期）。
/// 因为 wire 上的 `ts` 只精确到秒，验签时钟也取整到秒再比较——
/// 否则零点几秒签出的 token 一出生就带着最多 999ms 的"年龄"。
pub fn Signer::unsign(
  self : Signer,
  signed : String,
  max_age~ : Int64 = 0x7fffffffffffffffL,
) -> String raise SignError {
  guard signed.rev_find(":") is Some(i) else { raise BadSignature }
  let stamped = signed[:i]
  let provided = @base64.decode(signed[i + 1:], url_safe=true) catch {
    _ => raise BadSignature
  }
  guard constant_time_eq(provided, self.signature_bytes(stamped)) else {
    raise BadSignature
  }
  guard stamped.rev_find(":") is Some(j) else { raise BadSignature }
  let timestamp = b62_decode(stamped[j + 1:])
  let age = ((self.now)() / 1000).reinterpret_as_int64() - timestamp
  if age * 1000 > max_age {
    raise SignatureExpired
  }
  stamped[:j].to_owned()
}

///|
/// `sign_object`：Json 紧凑序列化后 base64url 编码再签名，
/// 返回 `data:ts:sig`。不压缩，Django `loads` 可直接校验。
pub fn Signer::dumps(self : Signer, obj : Json) -> String {
  self.sign(b64_encode(@utf8.encode(obj.stringify())))
}

///|
/// `unsign_object`：先 `unsign`，再 base64 解码并解析 Json。
/// 任何形式的载荷损坏都归为 `BadSignature`。`max_age`（毫秒）语义同 `unsign`。
pub fn Signer::loads(
  self : Signer,
  signed : String,
  max_age~ : Int64 = 0x7fffffffffffffffL,
) -> Json raise SignError {
  let data = self.unsign(signed, max_age~)
  let decoded = @base64.decode(data, url_safe=true) catch {
    _ => raise BadSignature
  }
  let text = @utf8.decode(decoded[:]) catch { _ => raise BadSignature }
  @json.parse(text) catch {
    _ => raise BadSignature
  }
}

///|
/// `django.core.signing.dumps`：对 `obj` 签名，返回 `data:ts:sig`。
/// 需要传入 `key`（即 Django 的 SECRET_KEY）；`salt` 用于用途隔离。
pub fn dumps(
  obj : Json,
  key~ : String,
  salt~ : String = "KKKIIO.moondark.signing",
) -> String {
  Signer::Signer(key~, salt~).dumps(obj)
}

///|
/// `django.core.signing.loads`：校验 `dumps` 的产出并还原 Json。
/// `max_age`（毫秒）超时时抛 `SignatureExpired`，默认永不超时。
pub fn loads(
  signed : String,
  key~ : String,
  salt~ : String = "KKKIIO.moondark.signing",
  max_age~ : Int64 = 0x7fffffffffffffffL,
) -> Json raise SignError {
  Signer::Signer(key~, salt~).loads(signed, max_age~)
}

///|
/// `value` 的 HMAC-SHA256 base64url 签名。等价于
/// `salted_hmac(salt + "signer", value, key, algorithm="sha256")`：
/// 派生密钥 `SHA256(key_salt + key)`，再对 `value` 做 HMAC-SHA256。
fn Signer::signature_bytes(
  self : Signer,
  value : StringView,
) -> FixedArray[Byte] {
  let hasher = @crypto.SHA256::new()
  hasher.update(self.key_salt)
  hasher.update(self.key)
  @crypto.hmac(
    @crypto.SHA256::new(),
    hasher.finalize().unsafe_reinterpret_as_bytes(),
    @utf8.encode(value),
  )
}

///|
/// base64url 无 padding 编码（Django 的 `b64_encode`）。
/// `@base64.Encoder` 的 `padding=false` 会丢掉末尾残余字符，
/// 所以先按 padded 编码再剥掉 `=`。
fn b64_encode(bytes : BytesView) -> String {
  let s = @base64.encode(bytes, url_safe=true)
  let mut end = s.length()
  while end > 0 && s[end - 1] == '=' {
    end -= 1
  }
  s[:end].to_owned()
}

///|
/// 恒定时间比较，防计时侧信道（Django `constant_time_compare`）。
fn constant_time_eq(a : BytesView, b : FixedArray[Byte]) -> Bool {
  guard a.length() == b.length() else { return false }
  let mut diff = 0
  for i in 0..<a.length() {
    diff = diff | (a[i].to_int() ^ b[i].to_int())
  }
  diff == 0
}

///|
/// Django 的 base62 字母表：数字 → 大写 → 小写。
let b62_alphabet : Bytes = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

///|
/// `b62_encode`：非负整数 → base62 字符串（"0" 特判）。
/// UInt64 最多占 11 个字符（62^11 > 2^64）。
fn b62_encode(n : UInt64) -> String {
  if n == 0 {
    return "0"
  }
  let digits = FixedArray::make(11, b'\x00')
  let mut i = 11
  let mut n = n
  while n > 0 {
    i -= 1
    digits[i] = b62_alphabet[(n % 62).to_int()]
    n /= 62
  }
  @utf8.decode_lossy(Bytes::from_array(digits[i:])[:])
}

///|
/// `b62_decode`：base62 字符串 → 整数。空串、非法字符、
/// 溢出 Int64 都抛 `BadSignature`。
fn b62_decode(s : StringView) -> Int64 raise SignError {
  guard !s.is_empty() else { raise BadSignature }
  let mut n = 0L
  for c in s {
    let d = match c {
      '0'..<='9' => c.to_int() - 48
      'A'..<='Z' => c.to_int() - 55
      'a'..<='z' => c.to_int() - 61
      _ => raise BadSignature
    }
    let d64 = d.to_int64()
    guard n <= (0x7fffffffffffffffL - d64) / 62 else { raise BadSignature }
    n = n * 62 + d64
  }
  n
}
