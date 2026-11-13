# Codex Signal 首版工程规格

> 本文为首版（0.1）规格，保留当时的范围与取舍。后续版本已加入自动接入 Hooks、应用内更新、开机启动和 Claude Code 支持，当前能力以 [README](../README.md) 与 [接入指南](CONNECT.md) 为准。下文不变量仍然有效，Claude Code 的增量见文末。

目标是将已选 B 会话伙伴岛交付为可构建、可启动、可回放验收的原生 macOS 应用。现有 design/DESIGN.md 是交互依据。首版实现通知闭环，真实 Codex 的覆盖范围由已验证事件能力决定。

## 范围

原生顶部浮层、纵向会话列表、原位展开、全部与待处理筛选、未查看计数、蓝色角色、收起状态、内置中文语音、声音暂停、勿扰时段、锁屏静音、会话来源降级跳转、持久化状态、只读 Hooks 接收桥和独立验收脚本均在本轮范围。

不实现浮层审批、回答问题、执行命令、远程服务、自动更新和登录项。准确定位会话只能在可靠目标可得时提供。首版只提供打开来源应用及复制会话标识，明确不能证明已经进入准确会话。点击打开应用不得自动标记已查看；另设显式已查看操作。

应用没有自动改写 Codex 配置的路径。生成 Hooks 配置供官方信任界面审阅。保留已有 notify。真实 CLI 和桌面生命周期分别验收，回放不能替代真实接入。

## 不变量

1. 一行以 source 与 sessionId 联合识别，同项目不同会话不合并。
2. phase 是枚举，包含 running、approval、question、completed、failed、stopped、disconnected。
3. seen 独立于 phase。已查看的审批和提问仍计入待处理。
4. 明确的恢复或新回合才解除等待。重复事件不再播报。过期回合事件不能覆盖新回合。
5. completed 仅表示本轮结束。工具报错不代表整轮失败，Stop 不代表成功。
6. 会话按最近状态更新时间从旧到新排列，最新会话位于底部；打开、重新展开或切换筛选时默认显示并选中最新会话。向上滚动查看旧会话，新状态更新对应行的位置。
7. 列表停在最新位置时跟随底部新内容，查看旧会话时保留阅读位置。相同更新时间保持稳定顺序，审批、提问等状态不覆盖时间顺序。筛选计数不受当前可见列表影响。
8. 语音只读固定状态短句，不读输入正文、工具参数或完整路径。子任务普通结束静音。
9. 重启恢复状态时不补播旧消息。暂停、勿扰、锁屏期间不积累恢复后补播队列。
10. 不根据无输出的时长猜测完成。无事件时显示尚未接入，不能宣称已连接所有会话。

## 原生呈现

沿用 design/ui/02-inbox.html 的黑色外壳、700 点目标宽度和单行展开。面板按屏幕可用尺寸收缩，读取 safeAreaInsets，内容不穿过刘海。无刘海采用屏幕顶部独立浮条。列表滚动，工具栏固定。标题允许换行，主动作至少 36 点。

事件到达只更新状态，不抢焦点。用户点击状态栏或浮条后才让面板接收键盘。面板失去焦点、切换应用或点击其他应用时自动收起；焦点转入声音设置弹窗时保持展开，在弹窗内操作不触发收起。Escape 收起，方向键切换，Return 打开来源。系统减少动态效果下不播放位移动画。首版使用静态角色，不引入持续动画。

语音使用 `Sources/SignalApp/Resources/Audio` 中的 MP3 文件，Codex 与 Claude Code 各四个（`codex-*`、`claude-*`），按来源与状态选择，空闲时立即播放，播放期间到达的提醒按顺序播放。默认开启，首次启动不会播放历史事件。设置预览复用 `codex-approval.mp3`。音频缺失或播放失败时跳过该条并记录日志，不阻塞事件接收。

## 能力边界

官方 Hooks 的 stdin JSON 与 notify 的 argv JSON 分开解析。已核实本机 CLI 0.167.0 与 hooks feature。可靠映射包括 UserPromptSubmit、PermissionRequest、Stop、Interrupt。SessionStart 不等于开始任务。

整轮失败标准事件可回放，但没有已验证的官方 Hook 来源。`request_user_input` 和 `request_user_input_async` 的 PreToolUse 映射 question，不能凭 PermissionRequest 推断提问。同步提问的 PostToolUse 可解除匹配请求，异步提问的立即返回不解除等待。客户端可能绕过默认工具 Hooks，不能承诺完整提问覆盖。PermissionRequest 缺失稳定请求标识时使用可解释的降级键，并记录去重限制。

桌面版 Hook 支持受实际版本和信任状态影响。本轮不读取私有数据库，不启动第二个 app-server 来冒充订阅现有桌面会话。

## 交付判定

本地构建与事件回放可判定 VERIFIED。真实 CLI、桌面事件、硬件刘海、多显示器、真实锁屏和听感需要各自证据。未触发的条件标记 NOT VERIFIED 或 INCONCLUSIVE，不写成全量验收通过。

## Claude Code 增量（0.7.0）

- source 增加 `claude`，与 Codex 来源并列；一行仍以 source 与 sessionId 联合识别，不同代理的同名会话不合并。不变量 1–10 同样适用。
- Claude Code 没有轮次标识，以每次提问的 `prompt_id` 作为 turnId；首次提问前的事件不写入。未经 `UserPromptSubmit` 出现的新 prompt_id（如 slash 命令）先补一个 started。授权与 `AskUserQuestion` 按工具调用关联，`PostToolUse` 解除对应请求。
- `StopFailure` 映射 failed，是首个注册的整轮失败 Hook，仅表示本轮因 API 错误结束，尚未实测。`SessionEnd` 将记录中的当前轮次收为 stopped（`/exit` 的 `SessionEnd` 自带新的 prompt_id，不使用）；Esc 中断和拒绝授权没有 Hook，状态保持到下一次提问或退出会话。不根据静默时长推断。
- 接入写入 Claude Code 的 `settings.json`，未检测到配置目录时不创建，Claude Code 自动载入，无需审阅。共享服务状态核对与本地标题索引只用于 Codex；Claude Code 只使用 Hook 提供的标题。
- 打开会话回到原终端标签页，找不到时在新标签页填入 `claude --resume`，不按标签页标题匹配。语音使用 `claude-*.mp3`，不播报“Codex”。
- Claude Code 会话使用原创橙色小螃蟹「钳钳」，Codex 会话沿用蓝色伙伴，见 [产品与交互设计](../design/DESIGN.md#claude-code-小螃蟹2026-11-13)。

Hook 映射与接入细节见 [接入 Claude Code](CONNECT.md#接入-claude-code)。
