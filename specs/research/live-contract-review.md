# 真实接入前的事件契约审查

用户目标是接入真实 Codex 测试。此审查只核对当前桥、状态核心、官方文档及 CodeIsland 来源检测。没有改用户配置，没有启动会话，没有操作 UI。结论为 ISSUES。

## 已复现的输入差异

2026-11-09 读取官方 Hooks 文档。UserPromptSubmit、Stop、Interrupt 均有 turn_id。SessionEnd 的正式样例只有会话级字段和 reason。PermissionRequest 的字段表没有 tool_use_id，PreToolUse 与 PostToolUse 有该字段。特殊工具可能不经过默认 Hooks。[官方 Hooks](https://learn.chatgpt.com/docs/hooks)

使用 Python 直接调用实际 `scripts/signal_bridge.py` 的 normalize，以文档字段构造无正文样例，得到以下结果。

```text
SessionEnd rejected: invalid turn id
Approval request kind: fallback
PostToolUse request kind: tool
Request identity matches: False
Parent-only session field considered child: False
```

这不是来自真实会话的事件捕获。它验证的是当前代码对官方形状的处理。

## 必须优先观察的问题

| 问题 | 代码证据 | 最小处理 |
|---|---|---|
| 注册了通常会被拒绝的 SessionEnd | normalize 将 SessionEnd 映射 disconnected，又要求 turn_id 非空。test_lifecycle_is_not_success_inference 为 SessionEnd 人为补了 turn_id | 首次真实接入配置暂不注册 SessionEnd，或单独设计会话级事件。不要伪造回合 ID |
| 审批解除可能一直等到回合结束 | PermissionRequest 无 tool_use_id 时用 fallback 摘要。PostToolUse 有 tool_use_id 时用 tool 前缀。SessionStore 只允许完全匹配的 requestId 解除等待 | 真实审批测试先记录字段名和 requestId 派生方式。若确实无稳定 ID，保留等待并明确限制。后续关联需要由已观察到的 PreToolUse 标识建立，不能遇到任意工具结束就解除 |
| 全局固定来源会误标另一客户端 | --print-hooks 把 --source cli 或 desktop 固定在所有命令中 | 全局接入改为有证据的自动判定，无法判定时拒绝并记录原因，或引入明确 unknown 状态 |
| 子任务身份来源未经证实 | normalize 只读取 parent_session_id。官方常用字段没有承诺该字段，且子代理相关 hook 的 session_id 可指父会话 | 本轮不要声称已经验证子任务隔离。忽略 SubagentStop 已避免直接把子任务结束映射为父任务完成；其余子任务工具事件仍需单独捕获证据 |

对于缺失 turn_id 的 Stop、Interrupt、UserPromptSubmit，当前拒绝策略符合严格契约。首次捕获如果缺失该字段，应记录版本与事件类型，再修改契约；不要用当前时间生成假回合。

Stop 表示 hook 生命周期中的停止点。其他 Stop hook 可以要求继续，当前桥无法知道其他 handler 的最终决定。原生 completed 文案仍只能表述本轮结束，不能宣称任务成功。空 stdout 是否被本机 Stop handler 接受应在实际 CLI 输出中检查，本次没有将其断定为故障。

## 自动来源的最小规则

以下是根据上游实现提出的工程规则，不是官方 payload 中的客户端标记。

检查 CodeIsland 固定提交 `03c77e9457f0adc56fa036caf4925e4a576b453b` 的 `Sources/CodeIslandCore/Models.swift` 中 `CLIProcessResolver.codexDesktopTermBundle` 和 `Tests/CodeIslandCoreTests/CLIProcessResolverTests.swift`。上游先找到最近的 codex 祖先进程，再读取其参数和直接父进程。

1. 从桥的父进程向上，跳过临时 shell，寻找最近的真实 codex 可执行文件。
2. 精确解析 argv 中的子命令。不能用 command 字符串包含 app-server 来判断；prompt、选项值和 exec 参数也可能包含这个词。
3. 只有最近 codex 的子命令为 app-server，其直接父进程的外层 bundle ID 为 com.openai.codex，且父可执行文件就在该应用的 Contents/MacOS 目录，才判定 desktop。
4. 最近 codex 为明确 exec 或交互 TUI 时判定 cli，即使该二进制存放在 Codex 或 ChatGPT 应用包里。
5. 其他 broker 启动的 app-server、云执行宿主、父链不可读、没有 codex 祖先都保持 unknown。当前标准事件只有两种来源，可先拒绝这些输入并记不含正文的诊断。
6. 只记录判定规则名、进程 ID 和可执行文件短名。不要把完整 argv 或环境变量写入日志，它们可能含提示词或凭据。

上游规则有针对嵌套 Codex CLI、应用内终端和工具 broker 的反例测试。它比检查路径中有没有 `.app` 更窄。当前系统还必须用真实 CLI 与桌面进程各验证一次，才能把这条建议标记为已验收。

## 本轮验收建议

记录真实事件的 hook_event_name、字段名集合、session_id、turn_id、tool_use_id 是否存在、归一化 kind、最终来源和拒绝原因。对话正文、tool_input、tool_response、完整命令均不落盘。保持当前 notify 原值。

开始与完成先形成一条真实闭环。审批、主动中断和桌面来源分别记录结果。提问、整轮失败、子任务与云会话均不能由第一条成功事件推断为通过。

Boundary Discipline 使修正集中在事件适配入口。Prove It Works 使官方样例检查与真实事件验收分开记录。
