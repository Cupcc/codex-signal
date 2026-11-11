# 2026-11-11：统一折叠入口，取消设置退场等待

## 现象

用户报告两条路径：展开面板、打开设置后，点击外部会先关闭设置再折叠面板，等待明显。直接点击面板的收起按钮，状态条仍会短暂跑到中间再回顶部。

运行实例来自项目的 `dist/CodexSignal.app`，没有 `--demo` 参数。修改保留工作区内已有的接入设置、音量和会话状态改动。

## 假设与证据

修改前分别验证两个假设：

- 失焦等待来自浮层和面板串行关闭。若失焦处理返回时面板已经开始收起，则这个假设不成立。
- 收起按钮绕过旧保护，在浮层仍附着时发布收起状态。若发布状态时浮层的 `parent` 已为 `nil`，则继续检查布局与窗口动画。

扩大原有原生窗口测试后，两个假设均得到支持。失活事件返回时 `model.expanded` 仍为 `true`。收起按钮调用的 `setExpanded(false)`、菜单栏 `toggle()` 和 `previewIslandNotice()` 则在设置窗口的 `parent` 尚未清空时发布了收起状态。

修改前检查的关键输出为：

```text
appDeactivated: model.expanded == true after the event
collapseButton: settingsWindow.parent != nil when expanded becomes false
menuBarToggle: settingsWindow.parent != nil when expanded becomes false
noticePreview: settingsWindow.parent != nil when expanded becomes false
```

完整运行记录写入 `/tmp/codex-signal-collapse-before.log`。一组预览用例未成功打开设置，不能算作顺序证据；其余失败覆盖上述两种错误。本文保存结论和关键摘录，避免依赖临时日志。

## 修复

`AppModel.expanded` 改为只读出口。所有调用者继续使用 `setExpanded(_:)`；该方法在发布收起状态前同步发送 `willCollapse`。`IslandPanel` 在这个边界关闭属于面板的浮层，嵌套帮助先于设置关闭。

面板在浮层显示通知中设置 `animates = false`。这既取消独立的浮层退场等待，也覆盖 AppKit 在收起操作到达前先关闭 transient 浮层的时序。仅在 `collapse()` 中临时取消动画太晚，系统可能已经开始退场。

删除原来的 `collapseAfterPopover` 和关闭完成后再次调用 `collapse()` 的逻辑。关闭通知只移除对应浮层的记录，已关闭的浮层不会影响下一次展开。

面板继续使用原有的 AppKit frame 动画，普通收起时长仍配置为 0.20 秒。没有新增固定延时、位置补偿或逐帧拉回顶部的逻辑。本次证明的是应用层的生命周期与入口错误，没有推断 AppKit 内部计算中间偏移的公式。

## 验证范围

`collapseClosesSettingsWithoutWaiting` 使用真实 SwiftUI 设置浮层，覆盖失活、收起按钮调用、菜单栏切换、提醒预览和原生浮层先关闭五类入口。展开到设置、设置到折叠分别使用 20、80、400 毫秒，共 45 组时序。

检查同时要求操作返回时已开始收起、发布状态前浮层已脱离父窗口，以及移动和尺寸通知中的顶部与水平中心保持固定。预览入口还检查提醒保留。测试结束时的等待仅用于观察动画，不是产品中的等待时间。

立即收起会打断尚未完成的展开动画。扩大检查后，原来的水平中心 0.5 点阈值偶尔失败，记录的偏差为 -1 点；顶部没有移动。在完全不打开浮层的 `interruptedAnimationsFinishAtLatestCollapsedFrame` 中临时增加重复切换与采样，也得到中心偏差 `[-1.0, -0.5, 0.0, 0.5]`，且原生中间 frame 的原点与宽度为整数点。该对照支持原生动画取整的解释。因此只将中途水平中心容差改为 1 点，顶部与最终 frame 的 0.5 点约束保持不变。临时重复切换和采样代码已删除，原始对照日志位于 `/tmp/codex-signal-frame-diagnostic-repeat.log`。

`collapseClosesNestedHelpAndSettingsBeforePublishing` 验证嵌套帮助与设置均先解除父子关系，并验证再次展开后设置仍能打开。

隔离运行通过 `./script/test.sh`：163 项 Swift 测试、45 组折叠时序、嵌套帮助与重新打开检查均通过。Python 桥接 30 项、关联 22 项、安装器 3 项、Hooks 配置 14 项也通过。完整日志位于 `/tmp/codex-signal-collapse-verified.log`。

原生窗口测试与应用实测分开运行。早期同时打开运行应用和测试窗口时，焦点转移使部分设置未成功打开；这类用例没有到达目标操作，不能用于判断折叠顺序。嵌套测试补齐与已有用例相同的首次显示稳定步骤后，通过独立运行和整套运行。

应用使用 `./script/build_and_run.sh --verify` 重新构建并以正常模式启动，进程路径为项目的 `dist/CodexSignal.app/Contents/MacOS/CodexSignal`。原生界面确认展开、设置浮层及首选终端、音量、退出控件可见，最终收起状态可见。

连续鼠标复验未完整完成。桌面自动化反复返回控件已失效及用户改变应用状态，重新读取时面板已经收起；坐标点击的后备方式也返回 `AXError.notImplemented`。这些最终截图不足以证明中途没有视觉跳动。本次顺序和中途位置结论来自真实原生窗口回归测试，不能把控件可见与进程启动当成逐帧视觉验证。尚未验证其他显示器、全屏空间及不同 macOS 版本。
