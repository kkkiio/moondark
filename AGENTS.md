# MoonDark AGENTS.md

MoonDark 是基于 MoonBack 的 MoonBit 后端框架（设计参考 [Django](https://github.com/django/django)）；本文件说明仓库布局、领域术语、强制规则和开发命令。

**Location:** 仓库根目录 `AGENTS.md`。

## Project Structure Guide

仓库是一个 `moon.work` 工作区，包含一个核心模块 `core/` 和三个数据库驱动模块；每个目录即一个 MoonBit 包，由该目录下的 `moon.pkg` 声明依赖。

### Repo Structure & Important Files

```text
.
├── AGENTS.md                     
├── README.md                     # 项目简介（面向用户）
├── moon.work                     # 工作区成员
├── justfile                      # check / fmt / test 快捷命令
├── core/                         # 模块 xziheng/moondark（包路径省略 core/ 前缀）
│   ├── moon.mod                  # 核心模块元数据与依赖
│   ├── auth/                     # xziheng/moondark/auth：凭据存储、Auth、SessionAuth、SocialFlow
│   │   └── oauth2/               # OAuth2/OIDC 协议层：Provider、Identity
│   ├── database/sql/             # Go database/sql 风格的连接池与查询 API（DB、Conn、Rows、Tx、Stmt）
│   │   └── driver/               # 驱动 trait：Driver、Connector、Conn、Stmt、Rows、Tx、Value
│   ├── migration/                # Migration、Migrator、按 Dialect 加载迁移文件
│   ├── sessions/                 # Session、SessionStore、会话中间件、MemorySessionStore
│   │   └── db/                   # 基于 database/sql 的 DBSessionStore
│   ├── signing/                  # 兼容 Django 的带时间戳签名（Signer、dumps/loads）
│   └── cmd/main/                 # 可执行入口（模板占位）
├── sqlite/                       # 模块 xziheng/moondark_sqlite：SQLite 驱动
├── postgresql/                   # 模块 xziheng/moondark_postgresql：PostgreSQL 驱动
├── mysql/                        # 模块 xziheng/moondark_mysql：MySQL 驱动
├── docs/research/                # agent 撰写的调研文档（HTML）
├── .agents/skills/               # 项目级 agent skills（如 write-snapshot-test）
└── .scratch/                     # 已 gitignore，agent 临时实验目录
```

### Package Layout

- 每个包包含实现文件、黑盒测试 `*_test.mbt`、白盒测试 `*_wbtest.mbt`，以及生成的接口文件 `pkg.generated.mbti`。
- `README.mbt.md` 是可执行文档：```` ```mbt check ```` 代码块会被 `moon test` 编译运行，```` ```mbt nocheck ```` 不会。同目录 `README.md` 是指向它的符号链接，只编辑 `README.mbt.md`。

## Domain Language

- **DB** — `database/sql` 中的连接池句柄，由 `DB::create` 与 `DBExecutor` 成对返回。
- **DBExecutor** — 驱动连接创建与销毁的池执行器，必须在 task group 中 `spawn_bg` 运行。
- **Driver / Connector** — 驱动模块实现的 trait，负责打开底层数据库连接。
- **BadConn** — 驱动报告的"连接已失效"错误，`DB` 据此换新连接重试。
- **Placeholder** — SQL 参数占位符，统一写 `?`（JDBC 约定），由各驱动翻译为方言写法。
- **Dialect** — `migration` 中的数据库方言枚举，决定迁移文件后缀。
- **Migration** — 一个具名的 SQL 或代码迁移步骤。
- **Migrator** — 在某个 `Conn` 上记录并执行 `Migration` 的运行器。
- **Session** — 一次浏览器会话的键值数据（`Json`），由会话中间件挂到请求上。
- **SessionStore** — 持久化 `Session` 的 trait（内存或数据库实现）。
- **Credential** — 绑定到某个 user id 的一条认证凭据（密码或 OAuth）。
  _Avoid_: User（框架不管理 users 表）
- **Identifier** — 凭据内的登录标识，如邮箱或 OAuth provider 的 subject。
- **Auth** — 基于 `CredentialStore` 的密码/OAuth 认证服务。
- **SessionAuth** — 把已认证 user 写入 `Session` 的登录态管理器。
- **SocialFlow** — 串联 `oauth2.Provider`、`Auth`、`SessionAuth` 的第三方登录流程。
- **Provider / Identity** — OAuth2/OIDC 提供方配置 / 提供方返回的用户身份。
- **Signer** — 用密钥和 salt 对字符串签名与校验的 Django 兼容签名器。

## Policies & Mandatory Rules

### Compatibility Policy

当修改公开 API（`pkg.generated.mbti` 中的内容）、数据库表结构或迁移格式时：

- 项目处于 0.x，不做稳定性保证。
- 直接迁移调用方，不写兼容层；确需保留的已废弃代码块放进该包目录的 `deprecated.mbt`。
- 在最终回复中说明有意引入的破坏性变更。

### Auth Scope

修改 `core/auth/` 时：只管理凭据与登录态，不要新增 users 表的增删改接口；用户业务数据由应用自行维护。

### Placeholder Convention

编写或修改 SQL（驱动、`sessions/db`、`migration`、测试）时，参数占位符一律使用 `?`；方言翻译只在驱动内部完成。例外：直接测试 PostgreSQL 原生 `$N` 行为的用例。

### Agent Author

在 `docs/research/` 撰写调研文档时，署名为 agent 自身，而不是仓库所有者。

## Operation Guide

### Development Workflow

修改 `*.mbt` 或 `README.mbt.md` 后，在仓库根目录依次运行：

```bash
moon check --deny-warn
moon test
moon info && moon fmt
```

等价的 just 命令：

```bash
just check
just test
just fmt
```

纯文档（`AGENTS.md`、`README.md`、`docs/`）变更可跳过以上步骤。

### Testing

- `postgresql/` 与 `mysql/` 的测试通过 `xziheng/testcontainers` 启动临时容器，需要本地 Docker 可用。只改 `core/` 或 `sqlite/` 时可只跑对应目录：
  ```bash
  moon -C core test
  moon test sqlite
  ```
- 只跑单个包：
  ```bash
  moon test core/<package-dir>
  ```
- 输出变化导致快照失败且确认新输出正确时，刷新快照：
  ```bash
  moon test --update
  ```

### Utilities & Tips

- 代码导航（定义、大纲、引用），详见 moonbit-agent-guide skill：
  ```bash
  moon ide outline core/database/sql
  ```
- 查看未覆盖的代码：
  ```bash
  moon coverage analyze > uncovered.log
  ```
