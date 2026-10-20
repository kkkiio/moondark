---
name: write-snapshot-test
description: 为 MoonBit 项目编写或修改快照测试。用于新增或调整使用 `inspect`、`debug_inspect`、`json_inspect`、`@test.Test` file snapshot 或 `moon cram` CLI 转录的测试，选择有业务含义的观察对象，保证输出确定，并审查 `moon test --update` 生成的 baseline。
---

# Write Snapshot Test

核心原则：快照是给 reviewer 看的文档。选择能直接解释被测行为的观察对象，让工具生成 baseline，不要手写预期值。

## 编写流程

1. 确定被测行为，找到最接近的现有测试，复用其构造方式和观察原语。
2. 选择观察对象（见「选择观察对象」）。
3. 消除不确定输入（见「确定性」）。
4. 写出最小完整场景，用 `moon test <path> --update` 生成 baseline；cram 转录则按规格手写期望输出。
5. 审查 snapshot diff，再用无 `--update` 模式复跑。

## 决策：用哪种断言

| 场景                                                          | 用                                         | 原因                                           |
| ------------------------------------------------------------- | ------------------------------------------ | ---------------------------------------------- |
| 可执行程序的 CLI 契约（stdout/stderr、退出码）                | `moon cram` 转录                           | 在进程边界观察真实用户可见行为。               |
| 完整的生成文件、多文件 artifact、长文本输出                   | `@test.Test` file snapshot                 | 保留完整 review diff，文件后缀可匹配真实格式。 |
| `ToJson` 表示本身有业务含义的结构化对象                       | `json_inspect(value)`                      | JSON 形状稳定可读。                            |
| 其他领域对象（诊断列表、状态投影、层级结构）                  | `debug_inspect(value)`                     | `derive(Debug)` 即可获得完整结构。             |
| 实现 `Show` 的标量或短文本                                    | `inspect(value)`                           | 比 `debug_inspect` 更可读。                    |
| 能从规格或不变量独立推导出 expected 的单个值（计数、id 相等） | `assert_eq(a, b)`                          | 失败定位精确，无需看快照。                     |
| 被测对象本身就是布尔谓词（如 `is_retryable(x)`）              | `assert_true(f(x))` / `assert_false(f(x))` | `inspect(..., content="true")` 是无信息快照。  |

- 判断 `assert_eq` 是否合适：不运行代码能否写出 expected。只能从运行结果抄过来的，用快照。
- 类型缺少 `ToJson` 或 `Debug` 时，补 `derive(...)`，不要为了能快照而拆散结构、丢弃 `Option` 或加 `unwrap`。
- `debug_inspect` 的调用写法（直接调用或 `@debug.debug_inspect`）以项目现有测试为准。
- 项目有自定义快照原语时优先沿用。例：图形项目的 `@capture_app.screenshot(path)`、Playwright 管理的 JSON 状态快照。

## 选择观察对象

- 优先观察函数的完整返回值、现有领域对象，或命名清楚的语义投影。
- 多个值共同描述一个结果时组成一个快照；互不相关的观察值保持独立，不为凑大快照合并。
- 按与规格的接近程度排序选择。例：公开返回值与诊断码 > 解析后的文档结构 > 运行时可观察状态（事件、焦点、store）。
- 排除偶然实现细节。例：运行时分配的数字 ID、私有 record 字段、内部缓存。

## 确定性

快照只有在相同输入产出相同输出时才有意义。优先把不确定来源作为参数注入，而不是事后处理输出。

| 来源                           | 处理                         | 例                                         |
| ------------------------------ | ---------------------------- | ------------------------------------------ |
| 随机数 / 随机 id               | 传入固定种子                 | `rand=@random.Rand::chacha8()`             |
| 时间戳                         | 传入固定时间                 | `now=1786903823973`                        |
| 当前目录 / 绝对路径 / 临时目录 | 传入固定路径或输出相对路径   | `cwd="/workspaces/project"`                |
| Map 迭代顺序                   | 排序后再快照，或使用有序结构 | `entries.sort_by_key(e => e.name)`         |
| 环境变量 / 用户配置目录（CLI） | 指向入库的隔离 fixture 目录  | `APP_CONFIG_DIR=tests/cram/testdata/empty` |

## File snapshot

```moonbit
test "snapshot rendered output" (t : @test.Test) {
  let output = render(fixture)
  t.write(output)
  t.snapshot(filename="render_basic.txt")
}
```

- 快照用户最终拿到的 artifact。例：formatter 之后的生成代码，而不是 emitter 的中间格式。
- 单个 artifact 使用与真实文件匹配的后缀，如 `.mbt`、`.json`。
- 多文件 artifact 在同一个 test 中按稳定顺序写成 `.txt` transcript，用 `===== <文件名> =====` 分隔，并写入每个文件的完整内容。
- `snapshot` 总会抛出测试框架异常：一个 test 只在末尾生成一份 file snapshot，需要多份 baseline 时拆成多个 test。
- 关系断言（如 offset 指向的目标、跨文件引用）放在 `snapshot` 之前。
- file snapshot 已覆盖的内容不再重复写内联 `inspect`。

## CLI 快照（`moon cram`）

`moon cram test <dir>` 构建 native 可执行文件并校验 Markdown 转录中的 ` ```mooncram ` 块（实验性功能，仅支持 native target）。

````markdown
参数互斥在解析阶段即被拒绝，不读凭证、不碰网络：

```mooncram {output_stream: stderr}
$ moon run cmd/app -- --no-session -c
Error: --no-session cannot be combined with --continue
[1]
```
````

- `$` 行是命令，其后是完整期望输出；非零退出码写成 `[N]`；断言 stderr 时标注 `{output_stream: stderr}`。
- 转录是功能规格层级的文档，可读性要求高于 `inspect` 快照：每个块前用一两句话说明该用例证明了什么。
- 手工编写期望输出，不用工具回填。期望输出应能从功能规格推断；先按规格写，再运行 `moon cram test` 验证，失败时判断是实现错还是规格错。
- 输出过长或无法从规格推断时，说明它不适合放进转录：在命令中投影到契约字段（例：`| jq -r '.type'`），或把细节下沉到单元测试快照。
- 只放离线、确定的用例；依赖网络或真实服务的转录放到单独目录并显式 opt-in。例：`tests/cram/` 离线，`tests/live/` 需 API key。
- 敏感环境变量在转录 frontmatter 的 `defaults.environment` 中清空，避免开发机配置影响结果。
- 同一 CLI 行为已有转录时，不在单元测试里再 `inspect` 拼出的 CLI 文本；单元测试快照内部结构。

## 黑盒约束

- 默认写黑盒测试 `*_test.mbt`，只通过公开 API 调用；`*_wbtest.mbt` 仅在项目已有约定时使用。
- 不为测试新增 `_for_test` 公开符号，也不为了能快照扩大公开 API。
- 私有状态不可观察时，改为断言公开行为。

## 反模式

### 布尔结果包进快照 tuple（坏）

```moonbit
debug_inspect(
  (text.contains("session"), text.contains("model_change")),
  content=((true, true)),
)
// review 看不到实际输出，失败时也不知道哪个 true 变了。
```

### 用子串断言代替完整输出（坏）

```moonbit
assert_true(text.contains("model_change"))
assert_false(source.contains("@tree.apply"))
```

正向子串只证明某段文本碰巧存在，负向子串只证明某种拼写没出现，都不能证明输出完整、可解析或语义正确。改为快照完整输出；同一输出已有完整快照时，不再补子串断言。

### 手写预期数组 / 预期 tuple（坏）

```moonbit
assert_eq(entries.map(e => e.id), ["e1", "e2"])
assert_eq((a, b.field1, b.field2), (expected_a, expected_b1, expected_b2))
// 新增字段或顺序调整后必须手工同步。
```

正确做法：

```moonbit
json_inspect(entries)
debug_inspect((a, b))
```

## 更新 baseline

1. 先运行定向测试看失败 diff。
2. 仅当变化符合预期行为时运行 `moon test <path> --update`；cram 转录按规格手工修改（见「CLI 快照」）。
3. 逐项审查 `content=`、`__snapshot__/` 或转录文件的 diff，不盲目接受大量更新；确认没有绝对路径、时间戳或临时目录混入。
4. 不手工美化 baseline。结果不对时，修改被观察的表达式后重新 `--update`。
5. snapshot 更新与对应行为变更放在同一个 commit。

## 与其他测试手段的边界

快照只负责审查输出形状和语义值。其他性质交给对应的手段，不要用快照或子串断言代替。例：

- 可编译性：对生成代码运行 `moon check`。
- 性能与交互：benchmark 或浏览器 E2E。
