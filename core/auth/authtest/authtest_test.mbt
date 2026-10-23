///|
async test "memory credential store passes the conformance suite" {
  @authtest.check_credential_store(@auth.MemoryCredentialStore())
}
