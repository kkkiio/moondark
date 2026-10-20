///|
async test "password set and authenticate roundtrip" {
  let auth = @auth.Auth(@auth.MemoryCredentialStore(), bcrypt_cost=4)
  // the app owns user rows; "u-1" is the id its own users table assigned
  auth.set_password("u-1", identifier="alice@example.com", password="s3cret")
  assert_eq(
    auth.authenticate_password(
      identifier="alice@example.com",
      password="s3cret",
    ),
    Some("u-1"),
  )
}

///|
async test "password authenticate rejects bad inputs" {
  let auth = @auth.Auth(@auth.MemoryCredentialStore(), bcrypt_cost=4)
  auth.set_password("u-1", identifier="alice@example.com", password="s3cret")
  assert_true(
    auth.authenticate_password(identifier="alice@example.com", password="wrong")
    is None,
  )
  assert_true(
    auth.authenticate_password(
      identifier="nobody@example.com",
      password="s3cret",
    )
    is None,
  )
}

///|
async test "duplicate password identifier raises IdentifierTaken" {
  let auth = @auth.Auth(@auth.MemoryCredentialStore(), bcrypt_cost=4)
  auth.set_password("u-1", identifier="alice@example.com", password="s3cret")
  try
    auth.set_password("u-2", identifier="alice@example.com", password="other")
  catch {
    @auth.IdentifierTaken(kind, _, identifier) => {
      assert_eq(kind, @auth.Password)
      assert_eq(identifier, "alice@example.com")
    }
    e => raise e
  } noraise {
    _ => fail("expected IdentifierTaken")
  }
}

///|
async test "oauth bind and authenticate" {
  let auth = @auth.Auth(@auth.MemoryCredentialStore(), bcrypt_cost=4)
  auth.bind_oauth("u-1", provider="google", identifier="sub-123")
  assert_eq(
    auth.authenticate_oauth(provider="google", identifier="sub-123"),
    Some("u-1"),
  )
  // same sub under a different provider is a different identity
  assert_true(
    auth.authenticate_oauth(provider="github", identifier="sub-123") is None,
  )
}

///|
async test "one user, many credentials" {
  let auth = @auth.Auth(@auth.MemoryCredentialStore(), bcrypt_cost=4)
  auth.set_password("u-1", identifier="alice@example.com", password="s3cret")
  auth.bind_oauth("u-1", provider="github", identifier="gh-42")
  auth.bind_oauth("u-1", provider="google", identifier="sub-123")
  assert_eq(auth.store.credentials_of("u-1").length(), 3)
  // all three routes resolve to the same user_id
  assert_eq(
    auth.authenticate_oauth(provider="github", identifier="gh-42"),
    Some("u-1"),
  )
  assert_eq(
    auth.authenticate_password(
      identifier="alice@example.com",
      password="s3cret",
    ),
    Some("u-1"),
  )
}

///|
async test "binding an already-taken oauth identity raises" {
  let auth = @auth.Auth(@auth.MemoryCredentialStore(), bcrypt_cost=4)
  auth.bind_oauth("u-1", provider="google", identifier="sub-123")
  try auth.bind_oauth("u-2", provider="google", identifier="sub-123") catch {
    @auth.IdentifierTaken(@auth.OAuth, "google", "sub-123") => ()
    e => raise e
  } noraise {
    _ => fail("expected IdentifierTaken")
  }
}

///|
async test "set_password change keeps the same credential key" {
  let auth = @auth.Auth(@auth.MemoryCredentialStore(), bcrypt_cost=4)
  auth.set_password("u-1", identifier="alice@example.com", password="s3cret")
  auth.set_password("u-1", identifier="alice@example.com", password="new")
  assert_true(
    auth.authenticate_password(
      identifier="alice@example.com",
      password="s3cret",
    )
    is None,
  )
  assert_eq(
    auth.authenticate_password(identifier="alice@example.com", password="new"),
    Some("u-1"),
  )
}

///|
async test "remove_credential detaches a login method" {
  let store = @auth.MemoryCredentialStore()
  let auth = @auth.Auth(store, bcrypt_cost=4)
  auth.bind_oauth("u-1", provider="google", identifier="sub-123")
  auth.bind_oauth("u-1", provider="github", identifier="gh-42")
  assert_true(store.remove_credential(@auth.OAuth, "github", "gh-42"))
  assert_true(
    auth.authenticate_oauth(provider="github", identifier="gh-42") is None,
  )
  assert_eq(store.credentials_of("u-1").length(), 1)
}

///|
async test "authenticate updates last_used_at" {
  let store = @auth.MemoryCredentialStore()
  let auth = @auth.Auth(store, bcrypt_cost=4)
  auth.set_password("u-1", identifier="alice@example.com", password="s3cret")
  guard store.find_credential(@auth.Password, "", "alice@example.com")
    is Some(cred) else {
    fail("credential missing")
  }
  assert_true(cred.last_used_at is None)
  ignore(
    auth.authenticate_password(
      identifier="alice@example.com",
      password="s3cret",
    ),
  )
  guard store.find_credential(@auth.Password, "", "alice@example.com")
    is Some(cred) else {
    fail("credential missing")
  }
  assert_true(cred.last_used_at is Some(_))
}

///|
async test "delete_credentials_of clears a user's credentials" {
  let store = @auth.MemoryCredentialStore()
  let auth = @auth.Auth(store, bcrypt_cost=4)
  auth.set_password("u-1", identifier="alice@example.com", password="s3cret")
  auth.bind_oauth("u-1", provider="github", identifier="gh-42")
  store.delete_credentials_of("u-1")
  assert_true(
    auth.authenticate_password(
      identifier="alice@example.com",
      password="s3cret",
    )
    is None,
  )
  assert_true(
    auth.authenticate_oauth(provider="github", identifier="gh-42") is None,
  )
}
