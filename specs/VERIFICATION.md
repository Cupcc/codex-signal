# Codex Signal 0.1 验收记录

2026-11-09，本机 macOS 26.6、Apple Silicon、Swift 6.3.3、Command Line Tools。首次构建结论为本地原生闭环 VERIFIED。后续真实 CLI 与共享服务接入已完成，增量结果见 [真实接入验收](LIVE-VERIFICATION.md)。原生应用已构建于 dist/CodexSignal.app，采用本地 ad-hoc 签名，未做公证或发布。

## 实际产物与测试

| 检查 | 结果 | 证据 |
|---|---|---|
| SwiftPM 构建与 .app 打包 | VERIFIED | `.audit/runtime/build.log`，`script/build_and_run.sh` |
| Swift 状态与语音策略测试 | 23 项通过 | `.audit/runtime/tests.log`，`script/test.sh` |
| Python 桥接测试 | 14 项通过 | 同上，`scripts/test_bridge.py` |
| 打包应用运行检查 | 7 项通过 | `.audit/runtime/runtime-verification.json`，`scripts/verify_runtime.py` |
| 移出构建目录运行 | VERIFIED。应用复制到临时目录，原 SwiftPM 资源目录临时隐藏，七项运行检查仍通过 | `.audit/runtime/portable-verification.json`，`.audit/runtime/portable-test.log` |
| 现有 Codex 配置 | config.toml 与 hooks.json 内容指纹不变 | `.audit/runtime/config-check.json` |
| 独立代码审查 | 发现并修复三个 P1 单元 | `specs/research/review.md`，`.audit/review/` |

运行检查以 `open -n` 启动真实 .app，每次使用隔离数据目录。覆盖 242 条逆序命名的积压事件、启动时不补播、匹配请求解除、旧回合不能覆盖新问题、重复输入不改状态、重启持久化和同目录第二实例退出。启动静音与重启静音检查实际启用了语音，持续观察超过三秒，speechCount 均为零。

这些输入均为人工标准事件。该结果不证明真实 Codex 客户端已发出事件，也不证明中文声音的听感。

## 原生交互

实际通过 CUA 操作原生应用，观察到下列结果。

- 蓝色角色 PNG 正确加载，黑色纵向会话列表显示桌面版与 CLI 来源。
- 点击审批行的标记已查看后显示已查看仍待确认，待处理仍为一项。
- 切换待处理筛选，已查看审批仍可见。
- 追加问题回放后计数从一项增加到两项，原审批仍保持选中和展开。
- 暂停语音后按钮显示恢复语音，列表与待处理计数保持。
- 声音设置弹层包含中文语音、勿扰时段与试听入口。
- Escape 收起，点击浮条可重新展开。
- 打开终端后的提示明确说明尚未精确定位，不自动标记已查看。

截图为 `.audit/runtime/native-verified.png`。截图后布局与交互保持一致。后续修复事件消费、应用进程锁及资源路径，已重新构建并完成运行检查。

## 独立审查的修复

旧实现先按文件名取前 200 条再排序，会把后续回合的问题拒绝并删除。修复为先解码全队列并按时间排序，再分批消费。启动时记录所有积压文件，后续批次也不播报。

旧应用可以有多个实例写同一目录。修复为模型创建前获取按数据目录区分的 flock 排他锁。运行检查证明第二实例退出，首实例 PID 和状态摘要保持。

复验程序保留于 `.audit/review/Reproduce.swift`，通过 `.audit/review/run.sh` 重跑。独立审查使用同模型代理，没有声称跨模型审查。当前会话没有可读取的完整 transcript，审计核对基于工具结果与文件证据。

打包检查发现 SwiftPM 的 Bundle.module 查找应用根目录下的资源 bundle，旧打包脚本放在 Contents/Resources，会回退源码构建路径。最终保持标准 Contents/Resources 结构，角色加载器显式查找打包资源，仅开发环境才回退 SwiftPM 路径。构建脚本执行严格签名校验，并在隐藏原构建资源时复验通过。

## 仍未验证的能力

| 条件 | 状态与原因 |
|---|---|
| 真实 CLI 生命周期 | VERIFIED。后续已安装并通过官方界面信任，真实开始、结束、审批、提问、中断与恢复见 LIVE-VERIFICATION.md |
| 真实桌面生命周期 | NOT VERIFIED。电脑操作工具拒绝控制 Codex 桌面应用，等待手动测试确认 |
| 提问与整轮失败自动覆盖 | CLI 提问已实测。整轮失败来源仍未验证 |
| 精确定位会话 | 首版未实现。打开来源应用和复制标识是明确降级 |
| 真实锁屏与声音听感 | NOT VERIFIED。已实现锁屏信号静音，未锁用户设备或做听感验收 |
| 全部硬件与辅助功能组合 | NOT VERIFIED。当前屏幕已观察，外接屏、无刘海、全屏、增大文字与 VoiceOver 未逐项实测 |
| 长期历史保留 | 会话和退役回合随使用增长，尚无自动归档清理策略 |
| 开机启动与系统通知中心 | 首版未实现。通过菜单栏与浮条呈现 |

Hooks 样例已生成在 specs/examples，仍须通过官方信任界面。不要直接覆盖已有 hooks.json。具体接入步骤见 [接入指南](CONNECT.md)。

## 重跑

```sh
./script/test.sh
./script/build_and_run.sh --build
python3 scripts/verify_runtime.py --check-speech --output .audit/runtime/runtime-verification.json
./.audit/review/run.sh
```

原生操作需要对当前窗口实际检查。真实来源、硬件和听感项目通过后，再更新相应行。


## 2026-11-09 标题、导航、UI 增量

50项Swift测试、37项Python测试通过，构建/签名验证通过。隔离打包运行验收8项通过，新增仅元数据变更不影响生命周期与播报的检查。标题、选中、筛选、设置浮层和长标题通过实际窗口检查；导航链接已由系统接受，但目标Codex窗口受CUA限制未目视核验。Terminal/iTerm实际定位与全部显示器组合仍未实测。详见 [本轮优化记录](OPTIMIZATION-2026-11-09.md)。

## 2026-11-09 失焦与时间线增量

会话改为按状态更新时间从旧到新排列，最新位于底部；展开和切换筛选默认选中并显示最新会话。取消展开期间的固定行序，保留更新时间相同的稳定顺序。面板新增窗口失焦、应用停用、工作区应用切换和岛外鼠标点击的收起处理，设置子窗口获得焦点时保持展开。

`./script/test.sh` 通过 65 项 Swift 测试、22 项桥接测试和16项关联测试，日志为 `.audit/runtime/focus-timeline-tests.log`。排序回归覆盖跨状态时间顺序、旧会话更新移到底部、相同时间稳定顺序、持久化、重新展开与筛选后默认选中最新会话。`./script/build_and_run.sh --verify` 构建、签名验证和启动检查通过，最终应用已恢复使用默认数据目录。

原生 CUA 使用隔离目录逐步生成18条会话，实际观察到初始显示底部最新、向上滚动查看旧内容、查看历史时新会话到达保持位置、返回底部后跟随新会话追加。声音设置和时段菜单操作保持展开；实际点击 Finder 窗口后自动折叠，重新展开回到最新。Command-Tab 已接入工作区通知，但本轮工具发送的快捷键未形成可确认的应用切换，不计作该快捷键的实测通过。

## 2026-11-13 Claude Code 接入

| 条件 | 状态与依据 |
| --- | --- |
| 配置合并与隔离 | 自动测试覆盖：合并进 settings.json、保留其他设置、未检测到目录不创建、两种接收器互不影响。`python3 scripts/test_configure_hooks.py -k Claude` |
| Hook 映射 | 自动测试覆盖：prompt_id 轮次、授权与提问按工具调用解除、会话结束收起当前轮次、只用 Claude Code 进程的 TTY、不读取 Codex 标题。`python3 scripts/test_bridge.py -k claude` |
| 应用侧接入、导航与语音 | 自动测试覆盖：接入状态、事件只计入 Claude Code 连接、标签页或 `claude --resume` 恢复、`claude-*` 音频。`./script/test.sh --filter 'claude'` |
| 非交互运行 | VERIFIED。Claude Code 2.1.323 的 `claude -p` 实测 `UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop`、`SessionEnd` 字段与映射一致，见 [接入指南](CONNECT.md#接入-claude-code) |
| 交互会话的授权、提问与 `/exit` 结束轮次 | VERIFIED。Claude Code 2.1.323，伪终端驱动的交互会话；Esc 中断和拒绝授权不触发 Hook，`idle_prompt` 不再使用。见 [接入指南](CONNECT.md#接入-claude-code) |
| 真实终端中的标签页定位 | NOT VERIFIED。等待实机记录 |
| `StopFailure` 整轮失败 | NOT VERIFIED。桥映射有自动测试，未触发真实 API 错误 |
