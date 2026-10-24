# MoonDark

[![CI](https://github.com/kkkiio/moondark/actions/workflows/ci.yml/badge.svg)](https://github.com/kkkiio/moondark/actions/workflows/ci.yml)
[![Coverage Status](https://coveralls.io/repos/github/kkkiio/moondark/badge.svg?branch=main)](https://coveralls.io/github/kkkiio/moondark?branch=main)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](https://github.com/kkkiio/moondark/blob/main/LICENSE)

Modern batteries-included backend framework for MoonBit, built on MoonBack.

## Quick Start

```mbt nocheck
///|
async fn main {
  let files = @files.CasFileStore::new(
    root="./uploads",
    catalog=@files.MemoryCatalog::new(),
    key="app-secret",
  )
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@logging.middleware())
    ctx.add_middleware(@csrf.middleware())
    ctx.add_middleware(@sessions.middleware(@sessions.MemorySessionStore()))
    ctx.use_(files.routes())

    ctx.get("/", (req, res) => {
      let session = @sessions.get_session(req).unwrap()
      let views = match session["views"] {
        Some(Number(n, ..)) => n.to_int() + 1
        _ => 1
      }
      session["views"] = Json(views)
      res.send_text("Views: \{views}")
    })
  })
  defer app.close()

  let server = @moonback.listen(port=3000)
  app.serve(server)
}
```

## Install

```bash
moon add KKKIIO/moondark

# Database drivers and persistent backends (pick one or both)
moon add KKKIIO/moondark_sqlite
moon add KKKIIO/moondark_postgresql
```

## Packages

| Package | Description | Key APIs |
|---|---|---|
| [`KKKIIO/moondark/sessions`](./sessions/README.mbt.md) | Cookie-backed HTTP session middleware and pluggable stores | `middleware`, `get_session`, `SessionStore`, `MemorySessionStore` |
| [`KKKIIO/moondark/auth`](./auth/README.mbt.md) | Password & OAuth2/OIDC authentication and session guards | `Auth`, `SessionAuth`, `SocialFlow`, `CredentialStore` |
| [`KKKIIO/moondark/database`](./database/README.mbt.md) | Scoped connection pool, transactions, and typed SQL queries | `DB`, `Conn`, `Transaction`, `GenericClient` |
| [`KKKIIO/moondark/migration`](./migration/README.mbt.md) | In-place SQL and code database migrations | `Migrator`, `Migration`, `load_schema` |
| [`KKKIIO/moondark/tasks`](./tasks/README.mbt.md) | Transactional background task queue and concurrent worker | `Task`, `Worker`, `DBTaskBackend` |
| [`KKKIIO/moondark/files`](./files/README.mbt.md) | File storage with content-addressed blobs and presigned URLs | `FileStore`, `CasFileStore`, `Catalog` |
| [`KKKIIO/moondark/csrf`](./csrf/README.mbt.md) | Stateless `Sec-Fetch-Site` / `Origin` CSRF protection | `middleware`, `CrossOriginProtection` |
| [`KKKIIO/moondark/logging`](./logging/README.mbt.md) | OTel-aligned access logging and error recovery middleware | `middleware`, `QueryLog` |
| `KKKIIO/moondark/signing` | Timestamped HMAC cryptographic signing | `Signer`, `TimestampSigner` |

## Integration Modules

Core packages define backend-agnostic interfaces and in-memory implementations for local development and testing. For production persistence, use an integration module:

- **`KKKIIO/moondark_sqlite`** — SQLite driver (`open_db`), `SqliteSessionStore`, `SqliteCredentialStore`, `SqliteTaskBackend`, `SqliteCatalog`.
- **`KKKIIO/moondark_postgresql`** — PostgreSQL driver (`open_db`), `PostgresSessionStore`, `PostgresCredentialStore`, `PostgresTaskBackend`, `PostgresCatalog`.
