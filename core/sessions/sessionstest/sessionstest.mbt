///|
/// Conformance suite for `@sessions.SessionStore` backends. Every
/// backend's tests call it with a store whose schema is already in
/// place (e.g. after applying the package's `schema.sql`). It only
/// touches the `sessionstest-k1` key and deletes it before and after,
/// so the table may hold other rows.
pub async fn check_session_store(store : &@sessions.SessionStore) -> Unit {
  let key = "sessionstest-k1"
  store.delete(key)
  // Deleting a missing key is a no-op.
  store.delete(key)
  assert_true(store.get(key) is None)
  let session = @sessions.Session::of_model(@sessions.SessionModel::{
    key,
    data: { "user": Json::number(1), "name": Json::string("moon") },
    expires_at: 2_000_000_000_000,
  })
  assert_false(store.update(session), msg="update of a missing key")
  assert_true(store.create(session), msg="create on a free key")
  assert_false(store.create(session), msg="create on a taken key")
  guard store.get(key) is Some(loaded) else {
    fail("created session not found")
  }
  let model = loaded.to_model()
  assert_eq(model.key, key)
  assert_eq(model.expires_at, 2_000_000_000_000)
  assert_eq(model.data, {
    "user": Json::number(1),
    "name": Json::string("moon"),
  })
  // Unchanged data still counts as an update (MySQL reports 0 changed rows).
  assert_true(store.update(loaded), msg="update with unchanged data")
  loaded.set("user", Json::number(2))
  assert_true(store.update(loaded), msg="update with changed data")
  guard store.get(key) is Some(updated) else {
    fail("updated session not found")
  }
  assert_eq(updated.to_model().data, {
    "user": Json::number(2),
    "name": Json::string("moon"),
  })
  store.delete(key)
  assert_true(store.get(key) is None, msg="get after delete")
}
