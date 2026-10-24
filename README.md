# MoonDark

[![CI](https://github.com/kkkiio/moondark/actions/workflows/ci.yml/badge.svg)](https://github.com/kkkiio/moondark/actions/workflows/ci.yml)
[![Coverage Status](https://coveralls.io/repos/github/kkkiio/moondark/badge.svg?branch=main)](https://coveralls.io/github/kkkiio/moondark?branch=main)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)

Modern Batteries-included backend framework, based on MoonBack.

## Install

Add MoonDark to your project:

```bash
moon add KKKIIO/moondark
```

Depending on the features you need, you may also need to add the following dependencies:

```bash
# Use SQLite as database
moon add KKKIIO/moondark_sqlite
# Use PostgreSQL as database
moon add KKKIIO/moondark_postgresql
```

## What you get

- [sessions](./core/sessions/README.mbt.md): Session management.
- [auth](./core/auth/README.mbt.md): User authentication including password and OAuth2/OIDC login.
- [tasks](./core/tasks/README.mbt.md): Transactional background task queue and worker.
- [files](./core/files/README.mbt.md): File/attachment storage with presigned upload/download URLs.
- [migration](./core/migration/README.mbt.md): In-place SQL and code database migrations.
- [database](./core/database/README.mbt.md): Scoped connection pool, transactions, and typed SQL queries (`SQLite` / `PostgreSQL`).
- [csrf](./core/csrf/README.mbt.md): Stateless `Sec-Fetch-Site` / `Origin` CSRF protection middleware.
- [logging](./core/logging/README.mbt.md): OTel-aligned access logging and error recovery middleware.

## Quick Start

```mbt
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
