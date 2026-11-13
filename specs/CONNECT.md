# 接入和回放 Codex 事件

安装、重新安装或升级后的首次启动会检查六项用户级 Hooks，无需运行命令或手动合并 JSON。普通启动不检查 Hooks。配置器保留其他 Hooks 和 notify，不修改信任记录。CLI 历史真实结果见 [真实接入验收](LIVE-VERIFICATION.md)，来源覆盖与限制见 [接入证据](research/architecture-b.md)。

## 自动接入

1. 打开 Codex Signal，等待“已配置 · 等待事件”。配置失败时，在设置中点击“重试”。
2. 在 Codex 桌面端打开“设置 → Hooks”，或在 CLI 运行 `/hooks`，审阅并信任 Codex Signal 的 Hooks。
3. 开启新会话。收到事件后，接入状态显示“已接收事件”。

应用检测 Python 3.9+，将桥接脚本安装到 `~/Library/Application Support/Codex Signal/Bridge/<内容摘要>/`，并检查 `~/.codex/hooks.json`。设置了 `CODEX_HOME` 时使用该目录。

安装后的首次启动按桥接脚本内容核对版本，与应用版本号独立。同版本且配置完整时，保留原文件内容和修改时间，不生成备份。只缺少部分事件时，仅补齐缺项；桥接版本不同时，原位更新对应接收命令，保留自定义来源、超时、分组、顺序及同组其他处理器。接收路径或 Python 路径失效时会修复。应用升级但桥接内容未变时不重写 Hooks。

应用使用版本号、构建号和可执行文件身份识别一次安装，在数据目录的 `codex-connection.json` 中记录检查结果。普通启动只恢复记录，不运行 Python、不读取或修复 Hooks。移动同一个应用不会触发检查，替换同版本的应用文件也会识别为重新安装。失败或中断同样留存记录，等待用户手动重试。

用户点击“一键配置”“重新配置”或“重试”时执行强制重配：重装桥接，移除本应用旧接收器并按默认设置重新生成六项 Hooks。同版本也会执行，清除本应用接收器的自定义来源、超时和匹配条件；同组其他处理器及其分组设置会保留。开发配置器对应参数为 `--force`。

需要添加、更新条目或强制重配时，原文件先备份为配置目录中的 `hooks.json.codex-signal-backup-<标识>`。格式错误或符号链接配置会显示失败并保留原文件。信任由 Codex 管理，新增或修改 Hooks 后可能需要重新审阅。[官方 Hooks 文档](https://learn.chatgpt.com/docs/hooks)

事件桥本身仍只接收事件，不安装配置。安装由独立的 `configure_hooks.py` 完成。

## 接入 Claude Code

安装后的首次启动同时检查 Claude Code。配置目录为 `~/.claude`，设置了 `CLAUDE_CONFIG_DIR` 时使用该目录。目录不存在时不创建，记录为“未检测到”，等待用户点击“一键配置”。检查结果单独记录在数据目录的 `claude-connection.json`。

配置器将八项 Hooks 合并进 `settings.json`：`UserPromptSubmit`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`Stop`、`StopFailure`、`Notification`（仅 `idle_prompt`）和 `SessionEnd`。接收命令使用 `--source claude`，不写 `statusMessage`，避免每次工具调用都显示在 Claude Code 的进度提示中。版本核对、缺项补齐、强制重配、备份和符号链接拒绝与 Codex 相同；`model`、`permissions`、`env`、`statusLine` 等其他设置原样保留。Claude Code 通过文件监视自动载入 Hooks，不需要审阅。开发配置器对应参数为 `--agent claude --config-home <目录>`。

Claude Code 没有轮次标识，桥使用每次提问的 `prompt_id` 作为 turnId。首次提问前的事件（如 `SessionStart`）没有 `prompt_id`，不写事件。

| Hook | 状态 |
| --- | --- |
| `UserPromptSubmit` | started；携带 `session_title` 时作为会话标题 |
| `PermissionRequest` | approval；与同轮 `PreToolUse` 按工具输入摘要关联到 tool_use_id |
| `PreToolUse` / `PermissionRequest`，工具为 `AskUserQuestion` | question；两者关联为同一请求 |
| `PostToolUse` | resumed；提问工具在用户回答后才返回 |
| `Stop` | completed |
| `StopFailure` | failed，仅表示本轮因 API 错误结束 |
| `Notification` 的 `idle_prompt`、`SessionEnd` | stopped；本轮已结束时忽略 |

Claude Code 不为 Esc 中断或手动拒绝授权触发 Hook。此时会话保持运行中或待确认，直到 Claude Code 报告输入空闲（约 60 秒）、会话结束或下一次提问。`idle_prompt` 和 `SessionEnd` 是客户端给出的空闲或结束信号，不是根据静默时长推断。子代理的工具事件属于同一会话和轮次；`SubagentStop` 不注册。

终端标识取自最近的 `claude` 祖先进程（npm 安装时为运行 Claude Code 的 node 进程）的 TTY，以及其所在终端应用。IDE 插件或无终端运行没有 TTY，打开会话时直接在首选终端新标签页填入 `cd -- <目录> && claude --resume <会话>`。Claude Code 的标签页标题来自对话内容，不做标题匹配。标题只使用 Hook 提供的自定义标题，不读取 `transcript_path` 指向的对话记录。

真实接入记录：Claude Code 2.1.323 的非交互运行（`claude -p`）确认了 `UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop`、`SessionEnd` 的字段与上表映射一致。交互会话中的授权、提问、`idle_prompt` 和标签页定位尚待实机记录。

## 先验证隔离回放

1. 构建应用后，用独立目录启动应用。

```sh
open -n dist/CodexSignal.app --args --data-dir /tmp/codex-signal-replay
```

2. 向同一目录写入演示事件。

```sh
python3 scripts/replay.py --data-dir /tmp/codex-signal-replay
```

3. 保持面板展开，追加一个问题。当前选中行应保持不变。

```sh
python3 scripts/replay.py --data-dir /tmp/codex-signal-replay --scenario new-question
```

4. 回放请求恢复和旧回合事件。旧回合结束不能覆盖新回合问题。

```sh
python3 scripts/replay.py --data-dir /tmp/codex-signal-replay --scenario resume
python3 scripts/replay.py --data-dir /tmp/codex-signal-replay --scenario stale
```

回放使用固定事件标识。在相同持久化目录中重复执行同一个场景会被去重。重新验收时使用新的隔离目录。`--scenario long-list` 增加 16 个演示会话。

指定 `--data-dir` 的运行不会自动修改真实 Codex 配置。测试自动配置时，同时传入 `--codex-home /tmp/codex-signal-test-home`，将配置写入隔离目录。`--demo` 始终跳过自动配置，界面上的配置按钮也不可用。

## 开发诊断：生成接收配置片段

日常使用由应用自动合并。仅检查生成内容时使用以下步骤。

1. 在仓库根目录生成配置片段。

```sh
python3 scripts/signal_bridge.py --print-hooks --source auto > /tmp/codex-signal-hooks.json
```

下载发布包的用户可以使用应用内置的桥接脚本，无需克隆源码：

```sh
python3 /Applications/CodexSignal.app/Contents/Resources/Bridge/signal_bridge.py --print-hooks --source auto > /tmp/codex-signal-hooks.json
```

`examples/hooks.*.json` 仅展示配置结构，脚本路径是占位符。实际接入应使用上面的命令生成本机配置。

2. 检查生成文件中的 Python 路径、脚本路径和数据目录。移动仓库后重新生成。
3. 在 Codex 官方 Hooks 界面审阅生成的 command hooks。CLI 使用 `/hooks`。将各事件的条目合并到现有配置，保留其他条目和现有 notify。不要直接用生成文件覆盖已有 hooks.json。
4. 通过官方信任审查后，开启一条可控 CLI 会话，分别检查开始、结束、审批和主动中断。为每种实际观察到的事件记录结果。

生成配置使用现有 CodeIsland Codex 接入的 nested hooks 格式，事件条目包含 `hooks` 数组，命令字段为 `type`、`command` 和 `timeout`。这是待官方信任审查的配置片段。生成命令不声明信任已完成。[官方 Hooks 文档](https://learn.chatgpt.com/docs/hooks)

## 识别事件来源

默认使用 `--source auto`。桥查看最近的 Codex 祖先进程。独立 exec 或 TUI 判为 CLI；app-server 的直接父应用确为 Codex 时才判为桌面版。共享 daemon 由 launchd 托管，无法从祖先链判断原始客户端，此时记录 unknown，界面显示来源待识别。没有可识别 Codex 祖先进程时拒绝输入并写诊断。

只有确认某配置专用于一个客户端时，才显式指定 `--source cli` 或 `--source desktop`。全局统一固定标签不代表自动来源检测。默认共享服务 CLI 已实测，桌面专属实测仍受工具访问限制。

桌面端通过 Review hooks 或 Settings → Hooks 审阅。单独检查真实桌面事件，不能用 CLI 或回放结果替代。当前云编排不保证调用本机 command hook。[官方 Hooks 文档](https://learn.chatgpt.com/docs/hooks)

## 单独检查 notify 输入

notify 模式接收一个 JSON 命令参数。保留现有 notify 配置。下面的命令只向隔离目录写一条人工样例。

```sh
python3 scripts/signal_bridge.py --input notify --source cli --data-dir /tmp/codex-signal-replay '{"type":"agent-turn-complete","thread-id":"notify-demo","turn-id":"turn-1","cwd":"/example/Atlas"}'
```

## 查看适配边界

`UserPromptSubmit` 映射 started，`Stop` 映射 completed，`Interrupt` 映射 stopped。completed 表示本轮结束，不表示测试成功。`SessionEnd` 只有带有效 turn_id 才能写 disconnected，默认不注册该事件，因为官方样例不提供 turn_id。

共享服务会话另有每 5 秒一次的只读状态核对，用于补回漏收的结束事件。当前仅核对本地来源元数据为 `source=vscode`、`originator=codex-tui` 的会话；通过已有服务的 `thread/turns/list` 获取状态，`itemsView=notLoaded` 不加载对话内容。按原会话和轮次匹配后，completed、interrupted、failed 分别修正为本轮结束、已停止、运行失败；修正不播报，也不重新打开已关闭的提醒。服务不可用、接口不兼容或找不到匹配轮次时保留原状态。独立 CLI 仍依赖 Hooks，不根据静默时长推断任务结束。排查依据见 [运行状态修复记录](RUNTIME-STATUS-FIX.md)。

`PermissionRequest` 映射 approval。若有 tool_use_id，requestId 为其稳定派生值。实际 CLI 的审批输入没有该标识，桥用已记录的 PreToolUse 关联唯一活动调用。Bash 仅按 command 摘要匹配，忽略审批特有的 description。记录不完整或候选不唯一时保持无 ID 降级，使用工具名和输入内容的 SHA-256 摘要。输入正文不进入事件文件或关联数据库。同一回合、相同工具输入的重复请求可能合并。这个降级方式无法证明两个相同请求是同一个实际请求。

`PreToolUse` 在工具名为 `request_user_input` 或 `request_user_input_async` 时映射 question。客户端可能绕过默认工具 Hooks，因此这不是完整提问覆盖承诺。

`PostToolUse` 仅在带 tool_use_id 时写 resumed，但忽略 `request_user_input_async` 的工具返回。异步提问发出后立即返回，不能据此判断用户已经回答。状态模型只在 requestId 与当前请求一致时解除等待。经过唯一调用关联的审批和同步提问可在工具结束时解除。异步提问保持待回答，直到新回合、明确恢复事件或本轮结束；普通工具活动不会清除它。目前 Hooks 没有经过验证的同轮异步回答事件，不能承诺用户回答后立即恢复运行状态。

每轮可保留多个待处理请求，匹配恢复只移除对应请求。完成消息先到时保留其 ID，迟到审批不会重新挂起。自动来源模式为同一会话和轮次固定关联分区，避免进程检测短暂失败拆散请求。消息覆盖和已知缺口见[消息与提醒链路审查](MESSAGE-AUDIT.md)。

`StopFailure`、普通工具 PreToolUse、没有关联标识的 PostToolUse、SubagentStop 和未知事件不写事件。标准 event 模式可用于经过验证的外部适配器提供 failed，但本桥不从单次工具错误推断整轮失败。

缺失 session_id 或 turn_id 的生命周期事件被拒绝。标准事件只保存来源、标识、项目目录短名、状态和时间。项目短名仍可能包含业务名称，语音不朗读输入正文。Hook 模式 stdout 始终为空，输入或目录失败时退出 0。其他输入模式失败退出 2。

每条事件是 0600 的独立 JSON，目录为 0700。单次输入上限 1 MiB，标准事件上限 64 KiB。收件目录达到 4096 项时停止接收并在 stderr 提示，避免应用长期未运行时无限积压。已有事件不会因此被删除。时间取桥接接收时刻，不承诺还原跨进程乱序的真实发生顺序。

## 运行桥接测试

```sh
python3 scripts/test_bridge.py
```

测试通过真实 Python 子进程检查 stdin、argv、退出码、隐私字段、重复标识、并发写入、符号链接拒绝和现有配置保留。测试使用临时 HOME，不改真实 Codex 配置。

近期事件元数据保存在应用数据目录 diagnostics，约保留 256 份。关联索引保存在 correlation，只含标识和摘要。`python3 scripts/test_correlation.py` 验证唯一关联、并发歧义、数据库忙和隐私行为。
