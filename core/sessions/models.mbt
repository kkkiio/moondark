///|
pub(all) struct SessionModel {
  key : String
  data : Map[String, Json]
  /// expires at (unix timestamp in seconds)
  expires_at : Int32
} derive(ToJson, FromJson)

///|
pub extend SessionModel with ToJson::{to_json}

///|
pub extend SessionModel with FromJson::{from_json}

///|
struct Session {
  /// session key, empty string for new session
  mut key : String
  data : Map[String, Json]
  /// expires at (unix timestamp in seconds)
  mut expires_at : Int32
  mut modified : Bool
  /// rotate to a fresh key on the next save (see `cycle_key`)
  mut cycled : Bool
  /// drop the stored row on the next save (see `flush`)
  mut flushed : Bool
}

///|
pub impl Default for Session with fn default() {
  Session::{
    key: "",
    data: {},
    expires_at: 0,
    modified: false,
    cycled: false,
    flushed: false,
  }
}

///|
pub extend Session with Default::{default}

///|
#alias("_[_]")
pub fn Session::get(self : Self, key : String) -> Json? {
  self.data.get(key)
}

///|
#alias("_[_]=_")
pub fn Session::set(self : Self, key : String, val : Json) -> Unit {
  self.modified = true
  self.data.set(key, val)
}

///|
/// The model persisted by `SessionStore` backends.
pub fn Session::to_model(self : Self) -> SessionModel {
  SessionModel::{ key: self.key, data: self.data, expires_at: self.expires_at, }
}

///|
/// Rebuild a session from its persisted model, marked unmodified.
pub fn Session::of_model(model : SessionModel) -> Session {
  Session::{
    key: model.key,
    data: model.data,
    expires_at: model.expires_at,
    modified: false,
    cycled: false,
    flushed: false,
  }
}

///|
/// Rotate the session key on the next save, keeping the data — Django's
/// `cycle_key()`: the stored row is moved to a fresh key and the response
/// carries the new cookie. Call on privilege transitions (login) to
/// prevent session fixation.
pub fn Session::cycle_key(self : Self) -> Unit {
  self.cycled = true
  self.modified = true
}

///|
/// Delete the stored session and all its data — Django's `flush()`. When
/// nothing is written afterwards the response expires the session cookie;
/// writing new data starts a fresh session under a new key. Call on
/// logout.
pub fn Session::flush(self : Self) -> Unit {
  self.data.clear()
  self.flushed = true
  self.modified = true
}

///|
pub(open) trait SessionStore {
  /// Get session by key
  async fn get(Self, key : String) -> Session?
  /// Create session, return true if created, false if already exists
  async fn create(Self, session : Session) -> Bool
  /// Update session, return true if updated, false if not found
  async fn update(Self, session : Session) -> Bool
  /// Delete session by key
  async fn delete(Self, key : String) -> Unit
}

///|
/// Django-style session key: `length` chars from [a-z0-9],
/// sampled from platform entropy.
fn get_random_string(length : Int32) -> String {
  let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  let buf = StringBuilder()
  for byte in @env.rand(length).unwrap() {
    buf.write_char(chars.get_char(byte.to_int() % 36).unwrap())
  }
  buf.to_string()
}

///|
/// Create `session` in `store`.
///
/// Creates a fresh key is generated and inserted;
/// on a key collision the insert is retried with a
/// new key, up to 10 attempts, mirroring Django's `SessionStore.create()`
/// but bounded so a broken RNG fails instead of hanging the request.
async fn create_session(store : &SessionStore, session : Session) -> Unit {
  for _ in 0..<10 { // retry up to 10 times
    session.key = get_random_string(32)
    if store.create(session) {
      return
    }
  }
  fail("failed to create session after 10 key attempts")
}

///|
struct MemorySessionStore {
  sessions : Map[String, SessionModel]
}

///|
pub fn MemorySessionStore::MemorySessionStore(
  sessions~ : Map[String, SessionModel] = {},
) -> MemorySessionStore {
  MemorySessionStore::{ sessions, }
}

///|
pub impl SessionStore for MemorySessionStore with fn get(self, key : String) -> Session? {
  self.sessions
  .get(key)
  .map(m => Session::{
    key,
    data: m.data,
    expires_at: m.expires_at,
    modified: false,
    cycled: false,
    flushed: false,
  })
}

///|
pub impl SessionStore for MemorySessionStore with fn create(self, session) {
  if self.sessions.get(session.key) is Some(_) {
    return false
  }
  self.sessions.set(session.key, SessionModel::{
    key: session.key,
    data: session.data,
    expires_at: session.expires_at,
  })
  true
}

///|
pub impl SessionStore for MemorySessionStore with fn update(self, session) {
  if self.sessions.get(session.key) is Some(_) {
    self.sessions.set(session.key, SessionModel::{
      key: session.key,
      data: session.data,
      expires_at: session.expires_at,
    })
    true
  } else {
    false
  }
}

///|
pub impl SessionStore for MemorySessionStore with fn delete(self, key : String) -> Unit {
  self.sessions.remove(key)
}

///|
pub extend MemorySessionStore with SessionStore::{get, create, update, delete}
