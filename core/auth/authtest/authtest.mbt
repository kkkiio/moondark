///|
/// Conformance suite for `@auth.CredentialStore` backends. Every
/// backend's tests call it with a store whose schema is already in
/// place (e.g. after applying the package's `schema.sql`). It only
/// touches the `authtest-u1`/`authtest-u2` user ids and cleans them
/// up before and after, so the table may hold other rows.
pub async fn check_credential_store(store : &@auth.CredentialStore) -> Unit {
  let u1 = "authtest-u1"
  let u2 = "authtest-u2"
  let password = @auth.CredentialModel::{
    user_id: u1,
    kind: @auth.Password,
    provider: "",
    identifier: "authtest-i1@example.com",
    secret: "hash1",
    verified: false,
    created_at: 1_700_000_000,
    last_used_at: None,
  }
  let oauth = @auth.CredentialModel::{
    user_id: u1,
    kind: @auth.OAuth,
    provider: "github",
    identifier: "authtest-sub-1",
    secret: "{\"access_token\":\"t1\"}",
    verified: true,
    created_at: 1_700_000_100,
    last_used_at: None,
  }
  let other = @auth.CredentialModel::{
    user_id: u2,
    kind: @auth.Password,
    provider: "",
    identifier: "authtest-i2@example.com",
    secret: "hash2",
    verified: true,
    created_at: 1_700_000_200,
    last_used_at: Some(1_700_000_300),
  }
  async fn cleanup() -> Unit {
    store.delete_credentials_of(u1)
    store.delete_credentials_of(u2)
  }

  cleanup()
  // Reads and writes on missing keys.
  assert_true(
    store.find_credential(@auth.Password, "", "authtest-i1@example.com") is None,
  )
  assert_false(store.update_credential(password), msg="update of unknown key")
  assert_false(
    store.remove_credential(@auth.Password, "", "authtest-i1@example.com"),
    msg="remove of unknown key",
  )
  // add + find.
  assert_true(store.add_credential(password), msg="add on a free key")
  assert_false(store.add_credential(password), msg="add on a taken key")
  guard store.find_credential(@auth.Password, "", "authtest-i1@example.com")
    is Some(loaded) else {
    fail("added credential not found")
  }
  assert_eq(loaded.user_id, u1)
  assert_eq(loaded.kind, @auth.Password)
  assert_eq(loaded.provider, "")
  assert_eq(loaded.identifier, "authtest-i1@example.com")
  assert_eq(loaded.secret, "hash1")
  assert_eq(loaded.verified, false)
  assert_eq(loaded.created_at, 1_700_000_000)
  assert_eq(loaded.last_used_at, None)
  // credentials_of returns a user's credentials in creation order.
  assert_true(store.add_credential(oauth))
  assert_true(store.add_credential(other))
  let creds = store.credentials_of(u1)
  guard creds is [c1, c2] else {
    fail("credentials_of should return both u1 credentials")
  }
  assert_eq(c1.identifier, "authtest-i1@example.com")
  assert_eq(c2.identifier, "authtest-sub-1")
  // update persists secret/verified/last_used_at.
  let changed = @auth.CredentialModel::{
    ..loaded,
    secret: "hash1b",
    verified: true,
    last_used_at: Some(1_700_000_400),
  }
  assert_true(store.update_credential(changed), msg="update of known key")
  guard store.find_credential(@auth.Password, "", "authtest-i1@example.com")
    is Some(updated) else {
    fail("updated credential not found")
  }
  assert_eq(updated.secret, "hash1b")
  assert_eq(updated.verified, true)
  assert_eq(updated.last_used_at, Some(1_700_000_400))
  // remove by natural key.
  assert_true(
    store.remove_credential(@auth.Password, "", "authtest-i1@example.com"),
  )
  assert_true(
    store.find_credential(@auth.Password, "", "authtest-i1@example.com") is None,
  )
  // delete_credentials_of removes only that user's credentials.
  store.delete_credentials_of(u1)
  assert_true(store.credentials_of(u1) is [])
  guard store.find_credential(@auth.Password, "", "authtest-i2@example.com")
    is Some(remaining) else {
    fail("other user's credential must survive delete_credentials_of")
  }
  assert_eq(remaining.user_id, u2)
  assert_eq(remaining.last_used_at, Some(1_700_000_300))
  cleanup()
}
