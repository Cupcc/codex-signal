# 排查手册

本目录保存可复用的排查步骤和故障记录。遇到相似症状时，先核对复现条件和证据，再决定是否沿用修复方案。

已记录的案例：

- [2026-11-10：设置失焦后，灵动岛折叠跳位](2026-11-10-popover-collapse.md)

## 排查窗口跳位、失焦和浮层关闭问题

### 1. 固定复现路径和运行产物

记录用户的完整操作顺序，包括展开、打开浮层、点击外部窗口等中间步骤。记录显示器是否有刘海，以及问题发生在动画中还是动画结束后。

先确认正在运行哪个应用包：

```sh
pgrep -fl CodexSignal
```

核对进程路径和启动参数。`/Applications/CodexSignal.app` 与项目的 `dist/CodexSignal.app` 可能并存；普通模式与演示模式也可能使用不同数据目录。不要把一个实例的画面与另一个实例的日志拼在一起。

需要从当前源码复现时，使用项目入口：

```sh
./script/build_and_run.sh --demo
```

该命令会重启 Codex Signal。演示模式使用独立数据目录。也要按用户原来的模式复验，避免演示数据掩盖问题。

### 2. 写下待验证的假设

在改代码前写清楚三件事：怀疑哪里出错、用什么观察区分原因、什么结果会推翻假设。

对于窗口跳位，分别检查窗口坐标、内容布局和浮层生命周期。若窗口坐标记录没有变化，但用户仍看到跳动，保留这个差异；不要直接认定是系统动画插值错误。

一项修复被用户复验否定后，先删除该次无效改动，再继续调查。同一前提下的修复反复失败时，停止叠加补偿代码，重新验证前提。

### 3. 对齐实际事件顺序

从 [IslandPanel.swift](../../Sources/SignalApp/IslandPanel.swift) 的 `collapse()` 和事件订阅开始，追踪到 [IslandView.swift](../../Sources/SignalApp/IslandView.swift) 的设置浮层。区分以下入口：

- 窗口失去键盘焦点：`NSWindow.didResignKeyNotification`。
- 应用失活：`NSApplication.didResignActiveNotification`。
- 切换到其他应用：`NSWorkspace.didActivateApplicationNotification`。
- 点击其他应用：全局鼠标事件监听。
- Escape、菜单栏切换、收起按钮和提醒预览。

逐项确认它们实际调用了哪个方法。应用内两扇窗口之间切换焦点，不一定覆盖点击其他应用的时序。

需要临时埋点时，在同一条时间线上记录事件名、`model.expanded`、浮层是否显示、浮层窗口的 `parent`、主面板的实际与目标 frame。围绕浮层记录 `NSPopover.willShowNotification`、`didShowNotification`、`willCloseNotification` 和 `didCloseNotification`。

用现有日志分类观察事件：

```sh
/usr/bin/log stream --style compact --level debug \
	--predicate 'category == "Windowing"'
```

当前代码不会常驻输出全部浮层通知。需要时增加临时日志，取证后删除。保存关键摘录及其来源，避免文档只指向会被清理的 `/tmp` 文件。

### 4. 先检查生命周期是否重叠

如果父窗口开始缩小时，浮层仍依附于父窗口，先让浮层完成关闭，再改变父窗口尺寸。

等待负责该浮层的原生组件发出完成通知。对于本案例，使用对应 `NSPopover` 的 `didCloseNotification`。不要把 SwiftUI 绑定变为 `false`、`onDisappear`、原生关闭开始和原生关闭完成当作同一个时刻。

重复到达的失焦事件只保留一次待折叠请求。关闭通知必须匹配当前浮层，避免其他浮层的通知触发折叠。

只有证据确认坐标计算或动画本身有错时，才修改那一层。不要先增加固定延时、循环拉回顶部或自定义逐帧动画。已有的位置修复只能证明最终位置可恢复，不能证明中途没有跳动。

### 5. 让检查覆盖失败过程

先让新增检查在未修复实现上因目标行为失败。若用户仍能复现、测试却通过，检查测试遗漏了什么事件和中间状态。

本案例的回归入口位于 [IslandPanelTests.swift](../../Tests/SignalAppTests/IslandPanelTests.swift)：

```text
IslandPanelTests.losingFocusClosesSettingsBeforeCollapsing
```

检查的关键约束是：主面板切换为收起状态时，设置窗口已解除与主面板的父子关系。最终 frame 正确只是其中一项检查。

使用项目测试脚本运行验证：

```sh
./script/test.sh
```

该脚本包含 Swift Testing 的框架路径处理。若裸 `swift test` 报 `no such module 'Testing'`，先核对测试入口，区分环境错误与行为失败。

### 6. 用原始操作完成视觉复验

重新构建应用后，按用户最初的步骤检查整个过渡过程：

```sh
./script/build_and_run.sh --verify
```

`--verify` 只证明应用进程已启动。继续实际打开设置、点击其他应用并观察收起过程；同时检查设置中的已有控件是否仍可见、可用。

若自动化只看到最终画面，或其焦点行为与实际鼠标操作不同，明确记录限制。必要时请用户按已固定的步骤复验，不要用测试通过代替视觉结论。

完成后清理临时埋点和无效实现，并分别记录自动测试结果、实际操作结果与未验证范围。新的排查记录沿用本目录案例中的“现象、证据、尝试、修复、验证范围”结构。
