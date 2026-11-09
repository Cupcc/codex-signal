# 候选 B 与 Codex 事件证据

目标是先写规格，再构建并验收已选 B 会话伙伴岛。此候选采用独立 SwiftPM 应用、薄事件桥和纯状态模型。调研日期为 2026-11-09。报告状态为 ISSUES，基础事件接入可实现，完整桌面生命周期仍有证据缺口。

## 已观察到的环境

本机执行 `codex --version` 返回 `codex-cli 0.167.0`。`codex features list` 的 hooks 行为 `stable true`。未读取用户会话正文，未修改 Codex 配置。

上游 CodeIsland 检出版本为 `03c77e9457f0adc56fa036caf4925e4a576b453b`。其 `Sources/CodeIslandCore/PrivateFiles.swift` 提供拒绝符号链接、校验所有者、目录 0700、文件 0600、原子 rename 的实现。可复用时保留 MIT 版权信息。其多来源状态系统远大于本次 Codex 专用需求。

## 可靠事件和限制

官方 Hooks 页已读取。command hook 从 stdin 接收 JSON。公共字段有 `session_id`、`cwd` 和 `hook_event_name`。回合事件带 `turn_id`。`PreToolUse` 与 `PostToolUse` 带 `tool_use_id`。`PermissionRequest` 的公开字段表没有承诺稳定请求 ID。hook 应返回 0 且 stdout 为空，不发审批决策。[官方 Hooks](https://learn.chatgpt.com/docs/hooks)

建议映射如下。

| 输入 | 状态 | 可信边界 |
|---|---|---|
| UserPromptSubmit | running | 记录新 turn，解除此前等待 |
| PreToolUse | running | 不把每个工具调用显示为新会话 |
| PermissionRequest | awaitingApproval | 同轮可合并，但无 request ID 时不能承诺精确请求去重 |
| PostToolUse | running | 同轮、匹配工具 ID 时才解除对应等待 |
| Stop | completed | 只称本轮结束，不称成功 |
| Interrupt | interrupted | 静音，不伪装完成 |
| SessionEnd | unknown 或离线 | 会话结束不等于任务成功 |
| SubagentStop | 不改父任务完成态 | 默认不播普通子任务结束 |

`request_user_input` 可作为经过验证的 PreToolUse 名称映射到 awaitingAnswer。官方说明某些专用工具可绕过默认 hook 路径，所以该映射须在具体客户端实测，不能声明已覆盖所有提问。常规 hook 没有独立的可靠整轮失败事件，单个 PostToolUse 失败不升级为整轮失败。[官方工具覆盖](https://learn.chatgpt.com/docs/hooks#tool-coverage)

官方 notify 目前只承诺 `agent-turn-complete`，JSON 通过命令参数传入。其字段包括 `thread-id`、`turn-id`、`cwd`。保留现有 notify，首版用独立 hook 接收器。单独提供 notify 解析入口可测试兼容性，但不自动改接用户接收器。[官方通知配置](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications)

新 hook 必须经过官方信任审查。hooks 文件与 inline TOML 可以合并加载，但不建议在同层同时使用。项目 hook 还受项目信任约束。当前云编排仅支持 Global MCP hooks，不能把本机 command hook 的可用性推广到云会话。[官方 Hooks](https://learn.chatgpt.com/docs/hooks)

## 上游接入机制与风险

CodeIsland 的 `Sources/CodeIsland/AppState+CodexAppServer.swift` 在检测到 Codex 桌面应用时启动自己的 `codex app-server` 子进程。该代码处理 `item/tool/requestUserInput`、thread 状态、请求解除。它还结合 `Sources/CodeIsland/Discovery/CodexDiscovery.swift` 和 `AppState+TranscriptTailer.swift` 扫描及跟随本地记录。

这套实现存在可参考的请求状态处理，但“启动另一个 app-server 就能订阅桌面全部会话”没有在本次实测中成立。官方 app-server 文档描述其连接上的 thread 和 turn 协议，并不构成跨进程广播承诺。首版不要自动启动一个旁路 app-server 并标成连接成功。[官方 App Server](https://learn.chatgpt.com/docs/app-server)

CodeIsland 的 `CodeIslandCore/JSONLTailer.swift` 识别 `task_started`、`task_complete`、`turn_aborted`、`turn_failed`。这是依赖私有记录格式的适配经验。首版不读取用户历史，未来适配必须声明版本、字段来源和测试样例。

## 数据形状

采用 Model the Domain 原则，事件与状态由类型表达。状态只在 reducer 中更新，UI 不解释原始 hook JSON。

```swift
struct SessionKey: Hashable, Codable {
    let source: Source
    let sessionID: String
}
enum Source: String, Codable { case cli, desktop, replay }
enum SessionPhase: String, Codable {
    case running, awaitingApproval, awaitingAnswer
    case completed, interrupted, failed, unknown
}
struct SignalEvent: Codable {
    let version: Int
    let eventID: String
    let session: SessionKey
    let turnID: String?
    let requestID: String?
    let kind: EventKind
    let receivedAt: Date
    let project: String
    let target: SessionTarget
}
struct SessionRecord: Codable {
    let key: SessionKey
    var activeTurnID: String?
    var phase: SessionPhase
    var viewed: Bool
    var updatedAt: Date
}
func normalizeHook(_ data: Data, source: Source, receivedAt: Date) throws -> SignalEvent?
func reduce(_ state: inout SignalState, event: SignalEvent) -> [Effect]
func markViewed(_ state: inout SignalState, session: SessionKey)
func visibleRows(_ state: SignalState, filter: SessionFilter, frozenOrder: [SessionKey]) -> [SessionRecord]
```

`SessionTarget` 使用显式类型保存 app bundle ID、session ID 和可选 terminal hint，不接受任意 shell 命令。来源识别来自安装入口或明确环境标记，无法识别时不猜桌面版。

事件 ID 取稳定字段的摘要。重复的同轮 Stop 只发一次交接提醒。无稳定请求 ID 的 PermissionRequest 用工具名和规范化输入摘要作降级键，标记这一限制。不将完整命令或私有正文写入提醒文件。

## 回合与阅读不变量

1. 会话键包括来源和 session ID。同项目两个会话保持两个对象。
2. reducer 保存退役 turn ID。旧 turn 的 Stop、PermissionRequest 或工具结果不能覆盖新 turn。
3. 已有活动 turn 时，只接受明确新回合开始事件切换到陌生 turn。没有已知回合时可由首条可靠事件建立基线。
4. 队列按接收时间排序不能证明事件发生顺序。缺乏原始序号时将跨回合乱序记录为限制，不以接收时间伪装解决。
5. markViewed 不清除审批或提问。结束事件查看后归档。
6. 打开面板时固定行序和选中对象。新事件只更新原行或追加，下次重新打开才按优先级排序。
7. 启动恢复持久化状态时不重放声音。声音 effect 只来自新的可靠交接。

## 传输与模块

采用 Boundary Discipline 原则。桥接器校验 JSON 和长度，输出最小标准事件。内部 reducer 只接收类型化事件。

- `SignalCore` 包含标准事件、reducer、排序与提醒决策。只依赖 Foundation。
- `signal-bridge` 读取 stdin hook 或显式 notify 参数。写每事件一个文件，写入临时文件后原子 rename。
- `EventInbox` 由应用单一消费者扫描应用专用目录。消费后原子保存状态，再删除事件文件。崩溃重复由 event ID 去重。
- `SignalApp` 持有 NSPanel、SwiftUI 列表、声音串行队列和固定显示器选择。

目录采用 Application Support/Codex Signal，权限 0700，事件文件 0600。文件名由 UUID 生成，不把输入路径或 session ID 拼入路径。限制事件大小、积压数量和已消费去重集合容量。失败静默返回且保留诊断计数，不能阻断 Codex。

备选 Unix socket 可以降低轮询，但需要处理应用未运行、连接超时、ACK 和重试。当前每事件文件方案更容易复验崩溃恢复，也避免多进程写同一 JSONL 文件的锁竞争。

## 最小验收

编译与纯 reducer 测试可验证类型和状态规则。事件回放可验证界面、列表身份、去重、阅读保持和声音 effect。CLI hook 子进程可用受控样例验证 stdin、空 stdout、退出码和原子队列。

未跑真实 Codex 回合前，真实 CLI 和桌面接入仍为 NOT VERIFIED。提问、失败、会话深链、锁屏静音必须分别验收，不能被回放测试替代。当前候选可先形成可运行应用与可复跑验收脚本，再执行获授权的真实接入验证。
