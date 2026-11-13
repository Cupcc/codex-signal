# 模块契约

实现前冻结 v1。Swift 5.9 包，macOS 14 起，无第三方运行时依赖。

## 数据形状

标准事件 JSON 使用 camelCase。

```json
{"schemaVersion":1,"eventId":"unique-id","source":"cli","sessionId":"session-a","turnId":"turn-1","requestId":null,"project":"API 服务","kind":"approval","occurredAt":1794200000.0,"isChild":false}
```

source 为 cli、desktop、unknown 或 claude。unknown 表示收到真实 Codex 事件，但共享服务使原始客户端无法判定；claude 自 0.7.0 起表示 Claude Code 会话。kind 为 started、approval、question、resumed、completed、failed、stopped、disconnected。occurredAt 为 Unix 秒。eventId、sessionId、turnId、project 非空且有限长，禁止 NaN 和无穷日期。未知枚举或 schema 拒绝。eventId 去重与语义去重共用状态写入结果。正文不进入标准事件。

## SignalCore

Sources/SignalCore 由核心代理独占。Tests/SignalCoreTests 同属核心代理。

```swift
public enum SessionSource: String, Codable, Sendable { case cli, desktop, unknown, claude }
public enum EventKind: String, Codable, Sendable { case started, approval, question, resumed, completed, failed, stopped, disconnected }
public enum SessionPhase: String, Codable, Sendable { case running, approval, question, completed, failed, stopped, disconnected }
public struct SignalEvent: Codable, Sendable { /* JSON 字段，与上述完全一致 */ }
public struct SignalSession: Codable, Identifiable, Sendable {
    public var id: String // source + ':' + sessionId
    public var source: SessionSource
    public var sessionId: String
    public var turnId: String
    public var project: String
    public var phase: SessionPhase
    public var seen: Bool
    public var updatedAt: Double
    public var requestId: String?
    public var pending: Bool // approval or question
    public var unread: Bool // 未查看的交接事件
}
public struct SessionStore: Codable {
    public init()
    public var sessions: [SignalSession] { get }
    @discardableResult public mutating func apply(_ event: SignalEvent) -> Bool
    public mutating func markSeen(_ id: String)
    public func sortedSessions() -> [SignalSession]
}
```

SignalEvent 必须提供同字段 public init，缺省 schemaVersion=1、requestId=nil、isChild=false。validated() throws -> SignalEvent 负责解码后的边界验证。仅应用了新语义状态时 apply 返回 true。去重与过期回合信息随 SessionStore 持久化。核心不 import AppKit。

## SignalApp

Sources/SignalApp/AppModel.swift、AppMain.swift、SpeechController.swift 由主代理负责。模型在 MainActor 上唯一持有 SessionStore。AppMain 在创建模型前获取数据目录的 flock 排他锁，防止多个实例覆盖状态。事件目录每个原子 JSON 一条，应用逐一解码并持久化成功后才删除。坏文件移到 rejected，不重试循环。启动恢复与收件历史不播报。--data-dir 指定隔离数据路径，--demo 注入显式演示数据。

Sources/SignalApp/IslandView.swift、IslandPanel.swift、MascotView.swift 由 UI 代理独占。

```swift
@MainActor final class AppModel: ObservableObject {
    @Published var sessions: [SignalSession]
    @Published var selectedID: String?
    @Published var pendingOnly: Bool
    @Published var expanded: Bool
    @Published var speechEnabled: Bool
    @Published var quietHoursEnabled: Bool
    @Published var quietStart: Int
    @Published var quietEnd: Int
    @Published var statusMessage: String
    @Published var isDemo: Bool
    var visibleSessions: [SignalSession] { get }
    var pendingCount: Int { get }
    var unreadCount: Int { get }
    func setExpanded(_ value: Bool)
    func select(_ id: String)
    func markSeen(_ id: String)
    func openSource(_ session: SignalSession)
    func copySessionID(_ session: SignalSession)
    func moveSelection(_ offset: Int)
    func previewVoice()
}
struct IslandView: View { @ObservedObject var model: AppModel }
@MainActor final class IslandPanel {
    init(model: AppModel)
    func show()
    func refresh() // follows model.expanded; screen-safe geometry
    func toggle()
}
```

UI 可直接用 Binding 切换筛选与声音，模型订阅偏好变化。不重写同一文件。UI 资源从 Bundle.module 的 Resources 加载，SVG 可复制转成 PNG，但转换工具与输入资产保留。AppMain 负责状态栏与生命周期。panel.show 不激活来源应用。

## Bridge

scripts/signal_bridge.py、scripts/test_bridge.py、scripts/replay.py 和 fixtures 由桥接代理独占。Python 3 标准库。--input hook|notify|event，--source cli|desktop，--data-dir path。hook/event 从 stdin，notify 从独立 argv 参数读取。标准事件写入 data-dir/inbox，用同目录临时文件与 rename 原子提交，目录 0700，文件 0600。不要输出 Hook 决策或覆写 notify。失败只在 stderr 输出诊断，Hook 模式退出 0 避免阻塞 Codex；测试可检查没有事件写入。

默认数据目录为 ~/Library/Application Support/Codex Signal。配置样本只生成，不安装。回放必须使用指定隔离路径。桥不携带对话正文或命令到事件文件。

## 持久化与限制

应用 state.json 原子存储 SessionStore，偏好存在同一数据目录 settings.json。不修改全局 UserDefaults。状态损坏保留副本，界面显示诊断。单事件最大 64 KiB，桥入口最大 1 MiB。首次版本不自动归档历史，验收记录历史增长限制。


## 2026-11-09 增量契约

schemaVersion 仍为 1，事件和会话增加可选 `title`（1024 UTF-8 字节）、`cwd`（绝对路径）、`terminalTTY`、`terminalBundleID`。旧事件与旧 state.json 无需迁移即可读取；无标题时 `displayTitle` 返回项目名。只读取标题元数据，不提取用户消息正文。

`SessionStore.updateMetadata(from:)` 与 `updateTitles(_:)` 只更新元数据，不改变 phase、seen、updatedAt、待处理计数或语音。应用每批最多200条事件，先原子保存整批归约结果，再清理收件；保存失败整批回滚，保存后清理失败可依赖事件ID去重重试。恢复历史仍静音。

标题索引每5秒检查文件指纹，仅变化或会话集合变化时后台读取，最多尾部8 MiB；I/O失败下次重试。SQLite补标题只在桥接收到事件时按精确ID只读查询。显示标题可以更新，不作为排序或路由标识。

导航只用 UUID 或 TTY，不使用项目名/窗口标题模糊匹配。`SessionNavigator.plan` 提供真实动作标题、图标与说明；运行中拒绝重复导航。恢复命令只复制，不自动执行。演示模式不打开真实应用。

## 0.7.0 增量契约：Claude Code

schemaVersion 仍为 1，标准事件字段不变。`SessionSource` 增加 `claude`，并提供 `isCodex`（除 claude 外均为 Codex）与 `isTerminalClient`（cli 与 claude，可在终端标签页恢复）。旧 state.json 无需迁移；新版写入的 claude 会话无法被旧版解码。

桥的 `--source` 取值为 auto、cli、desktop、unknown、claude。Claude Code 接收器固定使用 `--source claude`，不做进程来源推断；Hook 输入以 `prompt_id` 替换 turn_id，缺少时不写事件。`--print-hooks --source claude` 只输出 Claude Code 的七项 Hooks。

`configure_hooks.py --agent codex|claude --config-home <目录>` 分别写入 `hooks.json` 或 `settings.json`；`--codex-home` 保留为别名。两种接收器按 `--source` 区分，强制重配只重建对应代理的条目。应用为每个代理单独保存接入记录（`codex-connection.json`、`claude-connection.json`），状态快照增加 `claudeConnectionStatus` 与 `claudeConnectionHooksPath`。`--data-dir` 运行只有同时传入 `--codex-home` 或 `--claude-home` 时才配置对应代理。

`SessionNavigator.plan` 对 claude 会话：有可脚本化终端与 TTY 时返回原标签页，否则返回 `recover`，在新标签页填入 `claude --resume <会话>`；不使用标题匹配。`VoicePolicy.clip` 对 claude 来源返回 `claude-*` 音频，子任务结束仍静音。配置样例见 [examples/claude-settings.json](examples/claude-settings.json)。
