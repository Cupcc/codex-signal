# 面板收起后鼠标转彩球，长会话列表持续布局

2026-11-21 在 macOS 26.6 的 Codex Signal 0.8.1（Build 13）上取证。窗口已收起，鼠标移上去时出现彩球。主线程正在反复布局看不见的会话行，无法及时处理输入。修复提交为 `0c6454c`，随 0.8.2 发布。

## 现场证据

| 时间 | 观察 |
| --- | --- |
| 11 月 19 日 01:21 至 01:24 | 系统的 CPU 资源报告记录了无响应，主线程栈包含 `LazySubviewPlacements.updateValue()`。同一报告中，进程内存占用从 216 MB 增至 377 MB。 |
| 11 月 21 日 08:06 至 08:08 | 同一进程占用约一个 CPU 核心。两次 `sample` 都采到 SwiftUI 提交视图更新、计算懒加载列表行位置和查找会话 ID。原生窗口高度为 33 点。最后一次快照中 `expanded=false`，354 个会话中有 101 条可见。 |
| 08:07 的内存快照 | `vmmap -summary` 记录的进程 footprint 为 139.9 GB。默认 malloc 区有约 17 亿个仍分配着的块。`MALLOC_SMALL` 区约 138.2 GB，其中约 138.1 GB 记入换出列。该数字包含已经换出的页。 |
| 08:38 重启前 | 最后一次采样仍在计算列表位置，footprint 已增至 143.9 GB。原收件箱积压 4,097 个事件。 |

主线程采样中包含以下调用帧。

```text
NSHostingView.beginTransaction
  GraphHost.flushTransactions
    LazySubviewPlacements.updateValue
      LazySubviewPlacements.placeSubviews
        ForEachState.firstOffset
          SignalSession.id.getter
```

旧版对展开面板使用 `.opacity(0)`、关闭点击和隐藏辅助功能，但 SwiftUI 仍保留其中的 `ScrollView` 和 `LazyVStack`。现场采样定位了主线程卡住的位置。堆摘要只记录了分配区、块数和大小，缺少分配时的调用栈及对象引用链，具体是哪类对象持有了不断增长的小块内存仍待确认。

## 修复与回归

- 超过 8 条可见会话时，收起状态只向窗口报告高度上限，不创建滚动列表。展开时重建列表，按当前选择恢复位置。短列表使用普通纵向布局，保留实测高度。[视图实现](../../Sources/SignalApp/IslandView.swift)
- 排查中曾在收起时移除所有列表。快速展开短列表、打开设置并立即收起时，窗口动画来不及开始。最终实现只在收起时卸载长列表，并保留设置浮层的锚点。
- 以 101 条会话驱动真实面板，检查展开、收起、再次展开三个状态中的原生滚动视图。旧代码在收起后仍能找到滚动视图。修复后该测试通过。窗口和布局两个套件共 18 项测试通过，包含快速收起和浮层关闭时序。[面板回归测试](../../Tests/SignalAppTests/IslandPanelTests.swift)

## 恢复与验证范围

修复构建接管原数据目录后，4,097 个积压事件处理完毕。状态文件记录了 385 个会话，其中 132 条可见。展开、鼠标移入和收起均能响应。交互后的采样显示 footprint 为 49.7 MB，主线程已回到事件等待。随后 30 秒的六次观测为 48–49 MB。这里记录的是正式发布前的本地修复构建。

两个独立数据目录各放入 132 条合成会话，让旧版和修复版在收起状态下各处理相同的 40 轮重新排序。两者都处理完毕。这组短时输入没有重现旧版长时间运行时的异常增长。长期内存稳定性仍需验证。

## 下次出现同类问题时

1. 在重启前运行 `pgrep -fl CodexSignal`，核对进程路径、启动参数和数据目录。读取该目录的 `runtime-status.json`，记录 `processID` 和 `expanded` 的值、`sessions` 和 `visibleIDs` 的数量，以及 `inbox` 中待处理的 JSON 文件数。状态快照可能已过时，同时检查原生窗口实际尺寸。
2. 对同一 PID 取两次主线程采样，并记录内存摘要。执行下列命令时输入上一步核对的 PID。在 `/Library/Logs/DiagnosticReports/` 中按时间查找对应进程的 CPU 资源报告，比较卡住时和更早的调用栈。

   ```sh
   # 输入 PID，按回车
   read -r pid
   evidence=$(mktemp -d)
   sample "$pid" 3 10 -file "$evidence/first.sample"
   vmmap -summary "$pid" > "$evidence/vmmap.txt"
   sample "$pid" 3 10 -file "$evidence/second.sample"
   ```

3. 用修复版打开原数据目录，核对新 PID、收件箱排空和会话数量。实际展开、移入鼠标、收起，再看主线程能否返回事件等待。窗口测试会打开面板并切换焦点。在专用 Mac 上做版本对照，分别通过 `--data-dir` 指向隔离副本，避免把回放事件送入真实收件箱。
4. 如果内存继续逐轮上升，用 Instruments 的 Allocations 给相同工作负载分代，找出后续轮次仍存活的分配，再结合分配栈和 Memory Graph 检查持有链。[Apple 内存诊断指南](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use)
