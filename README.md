# MoonDark

[![Coverage Status](https://coveralls.io/repos/github/kkkiio/moondark/badge.svg?branch=main)](https://coveralls.io/github/kkkiio/moondark?branch=main)

Modern Batteries-included backend framework, based on MoonBack.

## Install

Add MoonDark to your project:

```bash
moon add xziheng/moondark
```

Depending on the features you need, you may also need to add the following dependencies:

```bash
# Use SQLite as database
moon add xziheng/moondark_sqlite
# Use PostgreSQL as database
moon add xziheng/moondark_postgresql
```

## What you get

- [sessions](./core/sessions/README.mbt.md): Session management.
- [auth](./core/auth/README.mbt.md): User authentication including password and OAuth2/OIDC login.
- [tasks](./core/tasks/README.mbt.md): Transactional background task queue and worker.
- [files](./core/files/README.mbt.md): File/attachment storage with presigned upload/download URLs.
- [migration](./core/migration/README.mbt.md): In-place SQL and code database migrations.
- [database/sql](./core/database/sql/README.mbt.md): Connection pool and SQL query API (`SQLite` / `PostgreSQL`).
- [csrf](./core/csrf/README.mbt.md): Stateless `Sec-Fetch-Site` / `Origin` CSRF protection middleware.

## Quick Start

```mbt
async fn main {
  let files = @files.LocalFileStore(root="./uploads", key="app-secret")
  let app = @moonback.App(ctx => {
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
