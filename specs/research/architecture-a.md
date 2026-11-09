# 候选 A 与上游复用依据

目标是先写 specs，再实现并验收 Codex Signal 的 B 会话伙伴岛。本文解释全量复用 CodeIsland 的路径，并给出适合当前首版的取舍。结论来自代码阅读，未构建或运行上游。

## Overview

CodeIsland 能提供会话发现、Hook 收取、纯状态归约、注意力决策、顶部原生窗口、终端定位和角色入口。全量 fork 的成本在于移除与 Signal 无关的行为，而不是添加角色。

检查版本为 CodeIsland `03c77e9457f0adc56fa036caf4925e4a576b453b` 与 Coucou `b1bc09de7f7c24a80bd8eca5729b8bee60f66402`。本地只读副本分别位于 `/tmp/codex-signal-codeisland` 与 `/tmp/codex-signal-coucou`。

## Key concepts

CodeIsland 的 `SessionSnapshot` 是会话状态值。`sessions: [String: SessionSnapshot]` 由主线程上的 `AppState` 管理。`HookEvent` 解析外部 JSON。`reduceHookEvent` 更新字典并返回生命周期副作用和事件事实，`AttentionPolicy` 再根据设置决定提醒。审批与问题通过独立请求队列保存。

`AgentStatus` 只有 idle、processing、running、waitingApproval、waitingQuestion。失败、结束、已查看和回合身份另外保存在字段中。直接用这个枚举不能表达 Signal 规格的全部状态。

`MascotView` 将来源映射到角色。Codex 当前进入 `DexView`。角色动画受 `MascotAnimationGate` 控制。Signal 可以在同一入口添加原创蓝色角色，但不需要拷贝其他供应商角色。

## How it works

上游启动顺序是创建 `AppState`，启动 Hook socket，安装宿主配置，创建 `PanelWindowController`，开始会话发现，再启动 Codex app-server 观察等功能。Hook 收到事件后在主线程改状态，窗口使用观察跟踪更新内容和显隐。

上游正常启动会调用 `ConfigInstaller.install()`，并存在定时修复配置。它还连接远程功能、push、硬件伙伴和更新器。`CODEISLAND_ISOLATED=1` 会禁用安装、发现和外部连接，且必须同时提供独立 `CODEISLAND_SOCKET_PATH`。隔离模式适合上游开发验证，不能当作首版真实接入方案。

CodeIsland 的辅助 Codex app-server 是新启动的进程。仅凭这段实现无法证明它收到其他桌面进程的所有实时事件。规格必须把真实桌面接入与事件回放分别验收。

## Where things live

所有 CodeIsland 路径都相对上述固定提交。

| 入口 | 依据 | 可用部分 |
|---|---|---|
| 构建 | `Package.swift` | SwiftPM、macOS 14，外部依赖 Sparkle 与 Yams |
| 启动 | `Sources/CodeIsland/AppDelegate.swift` | 非激活面板生命周期。默认安装副作用不移植 |
| 数据 | `Sources/CodeIslandCore/Models.swift:361` 与 `SessionSnapshot.swift:1146` | 状态枚举、Hook 模型、纯归约职责 |
| 提醒 | `Sources/CodeIslandCore/AttentionPolicy.swift` | 事件事实与提醒决策分离，子任务完成抑制，锁屏静音 |
| 窗口 | `Sources/CodeIsland/PanelWindowController.swift:283` | borderless、nonactivatingPanel、屏幕变化后重建布局 |
| 几何 | `Sources/CodeIsland/ScreenDetector.swift` | 安全区、辅助左右区域、AppKit 屏幕坐标换算 |
| 角色 | `Sources/CodeIsland/MascotView.swift` | 单一角色分派入口与动画开关 |
| 集成 | `Sources/CodeIsland/HookServer.swift` 与 `AppState+CodexAppServer.swift` | 输入解析边界，仅参考事实来源与失败处理 |
| 验证 | `Tests/CodeIslandTests/ScreenDetectorTests.swift` 与 `PanelWindowControllerTests.swift` | 多屏几何和窗口验证场景 |

Coucou 的 `NotchBuddy/Sources/CoucouKit/IslandScreenGeometry.swift` 仅依赖 Foundation。它将屏幕宽、安全区、左右辅助区和菜单栏高度转换成刘海宽高。无刘海时使用独立小条。这段纯几何最适合窄范围移植并保留署名。

Coucou 的 `NotchBuddy/Sources/App/IslandWindowController.swift` 同样采用 `NSPanel` 与 `NSHostingView`，但控制器还承担拖放、语音命令和多种内容。建议只参考面板配置。其 `project.yml` 指定 macOS 15、Swift 6、XcodeGen 与 FluidAudio。当前机器只有 Command Line Tools，直接接入整个 Coucou 工程不符合最小构建目标。

## 候选 A 结构草图

全量 fork 保留 `CodeIslandCore` 与原应用 target，增加 Signal 展示层和语音队列。调用者用 `SignalSessionProjection(snapshot:pendingRequests:)` 将上游状态投影为会话行，再交给 `SignalInboxView`。主动作只调用定位，不调用审批和回答 API。

拟定接口如下。它们仅是设计草图，并未写入应用代码。

```swift
struct SignalSessionProjection: Identifiable {
	let id: SessionIdentity
	let state: HandoffState
	let viewed: Bool
	let target: SessionTarget
}

enum HandoffState {
	case working
	case waiting(RequestIdentity, WaitKind)
	case ended(TurnIdentity)
	case failed(TurnIdentity)
	case stopped(TurnIdentity)
	case disconnected
}

@MainActor
final class SignalSpeechQueue {
	func enqueue(_ announcement: Announcement)
	func stop()
}
```

候选 A 的收益是现成终端路由和屏幕处理。代价是上游 `AppState.swift` 超过 4700 行，`NotchPanelView.swift` 超过 5800 行，审批控制与观察行为相连。为了禁用审批回答、其他供应商、自动配置、远程、更新与硬件功能，需要检查大量调用者。

## 选择建议

不选全量 fork 作为本轮基础。采用一个新的 SwiftPM 包，按 CodeIsland 的窗口与纯归约边界组织代码。保留单一 SessionStore、纯事件归约和独立提醒队列。窄范围复用 Coucou 几何，并保留上游文件与许可。上游终端定位等复杂能力在获得可靠事件来源后按实际需求移植。

这个选择由 Laziness Protocol 改变了实施范围。移植已读且需要的纯代码，避免先引入再禁用整套宿主控制。Model the Domain 改变了状态设计。等待请求与已查看分别编码，避免“查看”错误地解除审批。

## Gotchas

- CodeIsland MIT 许可允许复用代码，但须保留版权与许可文本。
- Coucou 源码是 MIT。`LICENSE-ASSETS.md` 明确将 Mochi 角色设计、表情、动画、名称、图标和声音排除在 MIT 之外。Signal 继续使用仓库已有原创蓝色角色与 macOS 中文系统语音。
- CodeIsland 原来的主动作包含允许、拒绝和回答。Signal 只能保留查看会话动作。
- 已查看不等于已处理。该差异不能只存在于 UI 文案。
- 上游普通启动会修改宿主配置。调研期间没有启动上游，也没有修改 Codex 配置。
- 代码里有 app-server 支持不等于真实桌面跨进程接入已经验证。

## 验证结果

PASS。两个仓库固定提交、构建清单、许可、窗口入口与状态入口已读取。架构候选和复用边界已写成可审查文档。

NOT VERIFIED。没有构建上游，没有运行其窗口，没有验证真实 Codex 事件。本文没有作这些能力已通过的声明。

## 来源

- [CodeIsland 固定提交](https://github.com/wxtsky/CodeIsland/tree/03c77e9457f0adc56fa036caf4925e4a576b453b)
- [Coucou 固定提交](https://github.com/Louis-CFM/coucou/tree/b1bc09de7f7c24a80bd8eca5729b8bee60f66402)
- [Coucou 素材许可](https://github.com/Louis-CFM/coucou/blob/b1bc09de7f7c24a80bd8eca5729b8bee60f66402/LICENSE-ASSETS.md)
