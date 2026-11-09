# 会话标题与定位元数据增量

2026-11-09。本轮保留已有事件归约模型，补齐标题和定位信息，不引入会话正文读取或第三方运行时包。

## 源码比较

- **CodeIsland `03c77e9`**：`Sources/CodeIsland/SessionTitleStore.swift` 的 `codexThreadName` 从各 Codex root 的 `session_index.jsonl` 按精确 `id` 取 `thread_name`，并以 `updated_at` 选择最新名称。`SessionStoreReaders.swift` 将该文件读取放到主 actor 之外；`CodeIslandCore/SessionHeadline.swift` 区分项目名与会话标题。本轮采用这些职责边界与文件字段，独立实现读取器，限制单次读取量并支持带毫秒时间戳。
- **Coucou `b1bc09d`**：`NotchBuddy/Sources/CoucouKit/IslandTypes.swift` 用 `sessionBundleId` / `hostApp` 保存会话宿主，适用于“打开终端”层级。当前检出的 Coucou 没有对应的 Codex `session_index.jsonl` 标题读取。Signal 因此采用 CodeIsland 的标题来源，将宿主 bundle 和 TTY 分开，精确目标由导航模块判断。
- 本机 Codex `state_5.sqlite` 的 `threads` 表存在 `id`、`title`、`cwd`，已只读检查表结构。桥只执行精确 ID 的 `SELECT title FROM threads WHERE id = ? LIMIT 1`；不查询 `first_user_message`、`preview` 或 rollout。

## 实现契约

`SignalEvent`、`SignalSession` 各新增四个可选字段；旧 schema 1 事件与旧状态仍能解码：

| 字段 | 来源与用途 |
|---|---|
| `title` | 显式 hook 标题 → `session_index.jsonl` 最新精确匹配 → `state_*.sqlite` 精确匹配。最多 1024 UTF-8 字节，空白归一化。无标题时 `displayTitle` 回退 `project`。 |
| `cwd` | Hook 的绝对工作目录，用于准确续接；保存在原有 0700/0600 本地数据中。相对目录或无效字段丢弃，不从 prompt 推断。 |
| `terminalTTY` | 仅 CLI 来源，从最近 Codex 祖先进程的 `ps tty` 获取并规范化为 `/dev/ttysNNN` 等受限格式。 |
| `terminalBundleID` | 仅 CLI 来源，从祖先应用 Info.plist 或已知 `TERM_PROGRAM` 映射获取。未知或桌面来源不猜终端。 |

`SessionStore.updateTitles` 与 `updateMetadata(from:)` 独立于生命周期变更；更新标题不会重置 `phase`、`seen`、`updatedAt`，不会产生提醒。新回合未提供终端元数据时清除上一回合的终端目标，防止沿用旧 TTY。独立可选 `latestMetadataAt` 记录 Hook 元数据时间，阻止较旧标题/路由覆盖较新值；即使值未变化也推进此时钟。它不参与生命周期事件的接纳判断，新回合单独重置，旧存储缺少字段仍可解码。

`CodexSessionIndex` 提供 `defaultURL`、`fingerprint`、`titles`、`readTitles`。读取优先 `CODEX_HOME`，否则 `~/.codex`；单次最多读取 index 尾部 8 MiB，跳过截断行、坏 JSON 与大于 64 KiB 的单行。`readTitles` 用 nil 区分 I/O 失败与成功但无匹配，供后台轮询重试。AppModel 用文件大小/修改时间加会话 ID 集合缓存，5 秒检查一次，不反复读取未变文件。

## 验证与边界

- Python 21 个桥测试、16 个关联测试通过；新增覆盖精确标题 ID、时间戳顺序、空白清理、只读 SQLite fallback、敏感正文排除、TTY 标准化及路由字段验证。
- Swift 元数据用例覆盖旧事件兼容、重命名保持等待/已查看状态、同阶段元数据更新、过时元数据拒绝、新回合清除旧 TTY、最新标题选择及超大 index 尾部读取。补充覆盖元数据乱序及重启持久化、相同值推进时钟、较早的有效生命周期仍可转移、新回合重置时钟、旧记录兼容。独立 scratch 构建的 Swift 核心 30 项测试通过；具体全量集成结果见主验收记录。
- 超过 8 MiB 的旧 index 条目可能不在读取窗口中：已有标题保留；新 Hook 可从只读数据库补齐。Swift 定时刷新只读 index，不轮询 SQLite，尚无 index 标题的历史会话需下一次真实 Hook 才能补齐数据库标题。
- SQLite 读锁冲突、格式变动、文件缺失只会造成标题暂缺，不影响事件接收。库按数字版本从新到旧尝试，最多 4 个，单库锁等待 50 ms。
- TTY 只能在可观测的 CLI 父进程链存在时捕获；共享服务保留 unknown 来源。是否成功打开具体会话由导航模块独立验证，不把获取 bundle 当成已定位。

## AppModel 独立读审

批处理先 `apply` 与独立元数据合并，持久化成功后再删除收件文件和发出生命周期提醒；保存失败回滚 store 并保留待重试文件。元数据变更不进入播报队列。异步标题更新只在主 actor 合并及保存，不覆盖其它会话状态；fingerprint 与 ID 集合缓存避免 UI 线程反复读取。未发现阻断项；已提醒主协调者对 I/O 失败不缓存读失败结果，采用 `readTitles` 的 nil 结果保留重试。
