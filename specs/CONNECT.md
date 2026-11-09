# 接入和回放 Codex 事件

本机已通过官方 CLI 界面接入六项 Hooks，真实结果见 [真实接入验收](LIVE-VERIFICATION.md)。此指南用于重新生成待审阅的 Hooks 配置。桥接器不安装配置，不修改 notify，也不修改信任记录。真实来源覆盖与限制见 [接入证据](research/architecture-b.md)。

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

## 生成 CLI 接收配置

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

`PermissionRequest` 映射 approval。若有 tool_use_id，requestId 为其稳定派生值。实际 CLI 的审批输入没有该标识，桥用已记录的 PreToolUse 关联唯一活动调用。Bash 仅按 command 摘要匹配，忽略审批特有的 description。记录不完整或候选不唯一时保持无 ID 降级，使用工具名和输入内容的 SHA-256 摘要。输入正文不进入事件文件或关联数据库。同一回合、相同工具输入的重复请求可能合并。这个降级方式无法证明两个相同请求是同一个实际请求。

`PreToolUse` 仅在工具名恰为 request_user_input 时映射 question。客户端可能绕过默认工具 Hooks，因此这不是完整提问覆盖承诺。

`PostToolUse` 仅在带 tool_use_id 时写 resumed。状态模型只在该 requestId 与当前请求一致时解除等待。经过唯一调用关联的审批可在工具结束时解除。无法关联的等待不会被任意工具结束误清除，需要新回合或其他明确恢复事件。

`StopFailure`、普通工具 PreToolUse、没有关联标识的 PostToolUse、SubagentStop 和未知事件不写事件。标准 event 模式可用于经过验证的外部适配器提供 failed，但本桥不从单次工具错误推断整轮失败。

缺失 session_id 或 turn_id 的生命周期事件被拒绝。标准事件只保存来源、标识、项目目录短名、状态和时间。项目短名仍可能包含业务名称，语音不朗读输入正文。Hook 模式 stdout 始终为空，输入或目录失败时退出 0。其他输入模式失败退出 2。

每条事件是 0600 的独立 JSON，目录为 0700。单次输入上限 1 MiB，标准事件上限 64 KiB。收件目录达到 4096 项时停止接收并在 stderr 提示，避免应用长期未运行时无限积压。已有事件不会因此被删除。时间取桥接接收时刻，不承诺还原跨进程乱序的真实发生顺序。

## 运行桥接测试

```sh
python3 scripts/test_bridge.py
```

测试通过真实 Python 子进程检查 stdin、argv、退出码、隐私字段、重复标识、并发写入、符号链接拒绝和现有配置保留。测试使用临时 HOME，不改真实 Codex 配置。

近期事件元数据保存在应用数据目录 diagnostics，约保留 256 份。关联索引保存在 correlation，只含标识和摘要。`python3 scripts/test_correlation.py` 验证唯一关联、并发歧义、数据库忙和隐私行为。
