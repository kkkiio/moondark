# MoonDark AGENTS.md

MoonDark 是基于 MoonBack 的 MoonBit 后端框架（设计参考 [Django](https://github.com/django/django)）。

**Location:** 仓库根目录 `AGENTS.md`。

## Project Structure Guide

仓库是一个 `moon.work` 工作区，包含核心模块 `core/` 和三个集成模块（`sqlite/`、`postgresql/`、`mysql/`）。

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
│   │   ├── driver/               # 驱动 trait：Driver、Connector、Conn、Stmt、Rows、Tx、Value
│   │   └── sqltest/              # 测试用内存驱动（FakeConnector）
│   ├── migration/                # Migration、Migrator、版本目录/schema 文件加载
│   ├── sessions/                 # Session、SessionStore、会话中间件、MemorySessionStore
│   │   └── sessionstest/         # SessionStore conformance test suite
│   ├── signing/                  # 带时间戳签名
│   ├── tasks/                    # 后台任务
│   └── cmd/main/                 # 可执行入口（模板占位）
├── sqlite/                       # 集成模块 xziheng/moondark_sqlite
│   ├── database/                 # database/sql 驱动、open_db；迁移在 SQLite 上的集成测试
│   ├── sessions/                 # SqliteSessionStore
│   └── tasks/                    # SqliteTaskBackend：单语句 CAS UPDATE claim
├── postgresql/                   # 集成模块 xziheng/moondark_postgresql
│   ├── database/                 # database/sql 驱动、open_db
│   ├── sessions/                 # PostgresSessionStore
│   └── tasks/                    # PostgresTaskBackend：FOR UPDATE SKIP LOCKED claim
├── mysql/                        # 集成模块 xziheng/moondark_mysql
│   ├── database/                 # database/sql 驱动：C FFI 直连 libmariadb（每连接一个 worker 线程跑 job）
│   └── sessions/                 # MysqlSessionStore
├── examples/todo/                # 示例应用 xziheng/moondark_example_todo：演示 migration 的典型接线
├── docs/research/                # agent 撰写的调研文档（HTML）
├── .agents/skills/               # 项目级 agent skills（如 write-snapshot-test）
└── .scratch/                     # 已 gitignore，agent 临时实验目录
```

### Package Layout

- 每个包包含实现文件、黑盒测试 `*_test.mbt`、白盒测试 `*_wbtest.mbt`，以及生成的接口文件 `pkg.generated.mbti`。
- 需要数据库表的集成子包（`sessions`、`tasks`）不在代码里建表：包内放 `schema.sql` 示例文件（scs 风格），测试直接读取并执行它，README 同步介绍。
- `README.mbt.md` 是可执行文档：```` ```mbt check ```` 代码块会被 `moon test` 编译运行，```` ```mbt nocheck ```` 不会。同目录 `README.md` 是指向它的符号链接，只编辑 `README.mbt.md`。

## Domain Language

- **DB** — `database/sql` 中的连接池句柄，由 `DB::create` 与 `DBExecutor` 成对返回。
- **DBExecutor** — 驱动连接创建与销毁的池执行器，必须在 task group 中 `spawn_bg` 运行。
- **Integration module（集成模块）** — 封装一种第三方技术、实现 core 后端接口的模块，如 `moondark_postgresql`。
  _Avoid_: 驱动模块、contrib
- **Backend** — 某个 core 接口的一个实现，如数据库驱动、`SessionStore`、任务后端。
- **Driver / Connector** — `database/sql/driver` 中的 trait，由集成模块的 `database/` 子包实现，负责打开底层数据库连接。
- **Migration** — 一个具名的 SQL 或代码迁移步骤。
- **Migrator** — 在某个 `Conn` 上记录并执行 `Migration` 的运行器。
- **Session** — 一次浏览器会话的键值数据（`Json`），由会话中间件挂到请求上。
- **SessionStore** — 持久化 `Session` 的 trait；内存实现在 `core/sessions`，数据库实现在各集成模块的 `sessions/` 子包。
- **Credential** — 绑定到某个 user id 的一条认证凭据（密码或 OAuth）。
  _Avoid_: User（框架不管理 users 表）
- **Identifier** — 凭据内的登录标识，如邮箱或 OAuth provider 的 subject。
- **Auth** — 基于 `CredentialStore` 的密码/OAuth 认证服务。
- **SessionAuth** — 把已认证 user 写入 `Session` 的登录态管理器。
- **SocialFlow** — 串联 `oauth2.Provider`、`Auth`、`SessionAuth` 的第三方登录流程。
- **Provider / Identity** — OAuth2/OIDC 提供方配置 / 提供方返回的用户身份。
- **Signer** — 用密钥和 salt 对字符串签名与校验的 Django 兼容签名器。
- **TaskResult** — 一次入队的执行记录（status、attempts、return_value、errors），backend 存取的快照。
- **TaskStore** — worker 侧存储协议：`claim`（原子领任务，FIFO + 僵尸行回收）与 `save`（写回终态）。

## Policies & Mandatory Rules

### Compatibility Policy

当修改公开 API（`pkg.generated.mbti` 中的内容）、数据库表结构或迁移格式时：

- 项目处于 0.x，不做稳定性保证。
- 直接迁移调用方，不写兼容层；确需保留的已废弃代码块放进该包目录的 `deprecated.mbt`。
- 在最终回复中说明有意引入的破坏性变更。

### Placeholder Convention

编写或修改 SQL 时，参数占位符使用目标后端的原生写法（SQLite/MySQL `?`，PostgreSQL `$N`），遵循 Go `database/sql` 与 Rust `sqlx`：

- 驱动必须原样透传 SQL，不做占位符翻译或其他改写。
- `core/` 中需要跨后端的 SQL（如 `migration`）按 `Dialect` 显式写出每个后端的语句。
- 依赖特定后端 SQL 的组件（如会话存储）放在对应集成模块的子包中实现，而不是在 `core/` 里抽象方言。

### Integration Module Layout

新增依赖第三方库的能力（数据库、会话存储、任务后端等）时：

- 放进对应集成模块中与所实现 core 包同名的子包，如 `postgresql/sessions` 实现 `core/sessions` 的接口；集成模块根目录不放包。
- 一个能力一个子包，子包只导入该能力需要的依赖。
- 公开类型带后端前缀（`PostgresSessionStore`），避免导入多个集成模块时混淆。
- 导入集成子包时显式写别名 `<集成模块目录名>_<包名>`，如 `"xziheng/moondark_postgresql/sessions" @postgresql_sessions`；集成子包内导入同名 core 包时写 `@moondark_<包>`，如 `"xziheng/moondark/sessions" @moondark_sessions`（否则黑盒测试会报别名冲突）。
- 后端测试调用 core 的通用测试套件（如 `@sessionstest.check_session_store`），不要在各集成模块重复写断言。
- `mysql/database` 依赖系统库 `libmariadb`（开发机装 `mariadb-connector-c`/`libmariadb-dev`）：moon 的 `link` 选项不沿依赖传递，凡把该包链进可执行产物的包（含测试 exe）都要在自己的 `moon.pkg` 重复 `link.native.cc-link-flags`（见 `mysql/sessions/moon.pkg`）。

### README is sales pitch

编写或更新 `README.md` 与 `README.mbt.md` 时：

- 只写面向用户的定位与快速上手路径。
- H1 下首段用 1 句话说明模块/包是什么、解决什么问题。
- `README.mbt.md` 第一个 H2 标题固定为 `Quick Start`，给出最小可运行的 `mbt check` 示例（仅在需要外部服务或监听端口时用 `mbt nocheck`）。

### Agent Research

在 `docs/research/` 撰写调研文档时，署名为 agent 模型名，而不是仓库所有者。
调研文档不写当前项目决策，只记录调研发现。

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

- `moon test` 是 workspace 级命令：在根目录、成员目录或 `-C <member>` 下都会跑整个工作区。`postgresql/` 与 `mysql/` 的测试通过 `xziheng/testcontainers` 启动临时容器，需要本地 Docker 可用。
- 只跑 core（不需要 Docker）：用 `MOON_WORK=off` 关闭工作区模式，只选中 `-C` 所在模块：
  ```bash
  MOON_WORK=off moon -C core test
  ```
- 按包名批量跑用 `-p`：先按完整包名精确匹配，失败才用 fzf 风格模糊匹配（按子序列匹配而非子串，`xziheng/moondark/` 也会匹配 `xziheng/moondark_sqlite/database`）。需要精确范围时用 `^` 前缀匹配或 `'` 子串匹配：
  ```bash
  moon test -p "'moondark_sqlite"        # sqlite/database + sqlite/sessions
  moon test -p '^xziheng/moondark/'      # core 的全部包
  moon test -p sessions                  # 模糊：所有名字含该子序列的包
  ```
- 只跑单个包（路径必须是含 `moon.pkg` 的目录，集成模块根目录不是包）：
  ```bash
  moon test core/<package-dir>
  moon test postgresql/sessions
  ```
- 加 `--outline` 只列出将要运行的测试而不执行，可先确认选中范围。
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
