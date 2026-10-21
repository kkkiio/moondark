///|
async test "memory session store passes the conformance suite" {
  @sessionstest.check_session_store(@sessions.MemorySessionStore())
}
