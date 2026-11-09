# Codex Signal 真实接入验收

2026-11-09，Codex CLI 0.167.0，使用现有 ChatGPT 登录。此次输入由真实 Codex 会话发出，没有用 replay.py 或标准 event 输入替代真实事件。

## 已启用的接入

全局接收配置位于 `~/.codex/hooks.json`。已在官方 CLI `/hooks` 界面查看桥接命令并信任六项 command hooks。没有直接写入信任哈希，也没有使用绕过信任参数。

启用 UserPromptSubmit、PermissionRequest、PreToolUse、PostToolUse、Stop 和 Interrupt。接收脚本为本仓库 `scripts/signal_bridge.py`，来源参数为 auto，写入 `~/Library/Application Support/Codex Signal`。应用以正式数据目录运行，isDemo 为 false。

notify 的值保持原样。官方信任记录之外的原 config.toml 配置也保持原样。CLI 首次启动写入的 tui.copy_on_select 默认项已恢复到接入前状态。备份位置保存在 `.audit/live/installation.json`，配置对比结果位于 `.audit/live/config-preservation.json`。备份只在用户 Codex 私有目录内，不复制到项目。

## 真实 CLI 结果

独立 CLI 测试会话为 `01a1c06f-3ad2-7982-86cb-94c8232b9576`，由 `codex --no-daemon` 启动。选择独立进程是为了单独验证来源识别，不绕过 Hooks 信任。

| 场景 | 实际动作与结果 | 证据 |
|---|---|---|
| 开始与结束 | 发送要求固定短句的真实提示。UserPromptSubmit 映射 running，Stop 映射 completed，触发一次系统语音调用 | `.audit/live/cli-completed.json` 与 event 文件 |
| 主动中断 | 真实执行 sleep 后按 Escape。Interrupt 映射 stopped，语音计数不增加 | `.audit/live/cli-running.json`、`cli-interrupted.json` |
| 审批 | 请求一次执行 `/usr/bin/true` 的审批，伙伴岛显示一项待处理 | `.audit/live/cli-approval.json` |
| 已查看仍待处理 | 在原生应用点击标记已查看，仍显示待确认，待处理仍为一项 | `.audit/live/approval-ui.png`、`approval-ui.txt` |
| 审批后恢复 | 仅批准执行一次 true。伙伴岛先恢复 running 和 pending=false，随后执行 sleep，最后 completed | `.audit/live/approval-fixed-transitions.jsonl` |
| 提问 | CLI Plan 模式实际调用 request_user_input，显示 Alpha/Beta 选择题，伙伴岛变为 question | `.audit/live/cli-question.json` |
| 回答后恢复 | 选择 Alpha。PostToolUse 解除待处理，先 running，再 completed | `.audit/live/question-transitions.jsonl` |

测试会话没有修改项目业务文件，没有发起部署或外部消息。审批仅选择一次性同意，没有添加永久命令放行规则。两个测试 CLI 客户端均已退出或断开。真实事件观察记录支持系统语音调用，以及 Interrupt 观察窗口内计数不增加；声音听感仍未人工判断。speechCount 是应用全局计数，不能将筛选后的共享会话快照计数解释为该会话累计数。

## 实测发现并修复的差异

PermissionRequest 实际没有 tool_use_id，但 PreToolUse 与 PostToolUse 有。审批的 tool_input 还额外包含 description。原实现产生两个不同 requestId，无法在工具完成时及时解除等待。

新增 request_correlation.py，按来源、会话、回合、工具输入摘要关联唯一活动调用。Bash 使用 command 作为摘要输入，不把审批说明视为另一条命令。SQLite 只保存标识和摘要，不保存命令或正文。多个相同输入同时在执行时不猜关联。Pre 记录失败时标记该回合不完整，后续保持降级状态。独立审查曾复现 SQLite 锁冲突下的错误关联，修复后原场景不再错误补 ID。

`.audit/live` 中的 PermissionRequest 记录仍保留原始字段集合及 toolUseIdPresent=false，requestId 是规范化后的结果。没有把补出的标识伪装成原始 Hook 字段。

SessionEnd 官方样例没有 turn_id，因此不再默认注册它。不会伪造回合或把会话结束当作任务成功。

## 共享服务结果

另用默认 CLI 启动真实会话 `01a1c07f-0592-7d40-a7fd-cb7b0a7d2f2c`，要求回复 SIGNAL_SHARED_SERVICE_OK。该会话实际由共享 app-server daemon 发出 UserPromptSubmit 和 Stop，应用接收并显示本轮结束。

共享服务的 Codex 进程由 launchd 托管，父进程为 1。Hook 的祖先链中没有原始 CLI 或桌面客户端。不能因为路径属于某应用就断言是桌面会话。规范事件现支持 source=unknown，界面显示来源待识别，主动作复制会话标识。证据为 `.audit/live/shared-service-result.json` 及同会话 event 文件。

这个测试证明默认共享服务事件可接入，不证明来源已经能准确区分桌面版和 CLI。

## 桌面端限制

电脑操作工具拒绝访问 `com.openai.codex`，原始原因是 `Computer Use is not allowed to use the app 'com.openai.codex' for safety reasons.` 没有改用其他工具绕过该限制。

已请求用户手动创建一条只回复 SIGNAL_DESKTOP_OK 的桌面测试会话，等待确认后核对接收结果。当前桌面专属测试为 NOT VERIFIED，不能用共享服务 CLI 的结果替代。

全局 Hooks 对受支持的本地客户端生效，但已有会话是否热加载、桌面专用工具、云会话、终止错误及子任务隔离仍须逐项验证。提问结论仅覆盖本机 CLI 0.167.0 的实测路径。

## 回归与诊断

`script/test.sh` 已包含核心、语音、桥接和关联测试。此次共 24 项 Swift 测试、16 项桥接测试和 16 项关联测试通过。打包产物重新构建并通过严格签名校验。7 项隔离打包运行检查也全部通过，覆盖积压顺序、历史不补播、请求匹配、去重、重启恢复及单实例；证据为 `.audit/runtime/live-runtime-verification.json`。这些运行检查使用人工事件，与上面的真实来源测试分开记录。

独立代理已核对代码、23 份真实事件元数据及状态转换，未发现新的阻断项，见 [独立审查](research/live-final-review.md)。审查提出的信任操作和语音计数表述已收紧。

`observe_live.py` 可观察指定会话的状态转换，不保存项目名或对话正文。桥的 diagnostics 只保留最多约 256 份近期事件元数据，目录 0700，文件 0600。记录字段名、标识、规范状态和诊断原因，不记录 prompt、tool_input、tool_response 或完整 argv。

```sh
./script/test.sh
./script/build_and_run.sh --build
python3 scripts/observe_live.py --session <测试会话ID> --source cli --seconds 30 --output .audit/live/observe.jsonl
python3 scripts/verify_runtime.py --check-speech
```

接入后的诊断可在 `~/Library/Application Support/Codex Signal/diagnostics` 检查。移动仓库后需要重新生成 Hook 命令并通过官方界面重新审阅。

## 依据

真实 Hook 的字段与信任流程对照 [官方 Hooks 文档](https://learn.chatgpt.com/docs/hooks)。自动来源分类是基于本机进程证据的工程规则，不是官方 payload 承诺。
