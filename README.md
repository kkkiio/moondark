# MoonDark

[![Coverage Status](https://coveralls.io/repos/github/kkkiio/moondark/badge.svg?branch=main)](https://coveralls.io/github/kkkiio/moondark?branch=main)

Modern Batteries-included backend framework, based on MoonBack.

## 模块

`xziheng/moondark`（`core/`）定义框架接口，只包含无第三方依赖的实现。依赖第三方技术的后端由集成模块提供，每个能力是一个与 core 包同名的子包：

| 集成模块 | `database` | `sessions` |
|---|---|---|
| [`xziheng/moondark_sqlite`](sqlite/README.mbt.md) | SQLite 驱动 | `SqliteSessionStore` |
| [`xziheng/moondark_postgresql`](postgresql/README.mbt.md) | PostgreSQL 驱动 | `PostgresSessionStore` |

SQL 使用各后端的原生占位符（SQLite 为 `?`，PostgreSQL 为 `$1`、`$2`…），驱动不改写 SQL。
