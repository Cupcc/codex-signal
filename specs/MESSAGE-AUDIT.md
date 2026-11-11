# 消息与提醒链路审查

2026-11-11，检查消息遗漏、请求错配和提醒失效。范围包括 Hook 归一化、请求关联、会话状态、来源迁移、语音队列和浮岛提醒。

## 已复现并修复

| 问题 | 原因 | 修复 |
|---|---|---|
| 问题未回答，另一个审批完成后却显示运行中 | 单个 requestId 被后来的请求覆盖，原请求被误记为已解决 | 每轮保存待处理请求集合，匹配恢复只移除对应请求 |
| 工具完成先到，迟到审批让会话重新等待 | 没找到当前请求就丢弃恢复消息 | 保存当前轮次的已完成请求 ID，拒绝该 ID 的迟到等待消息 |
| 同批已解除的问题仍播报等待回答 | 语音使用中间事件，没有核对最终状态 | 整批处理后按最终会话、轮次、状态和请求筛选播报，另行清理过期队列 |
| 来源从未知识别为 CLI 后，浮岛漏显示或提前关闭 | 提醒仍持有旧来源身份 | 重新规范候选事件来源，现有提醒只跟随唯一已确认来源，保留原到期时间 |
| 来源进程检测短暂失败后，审批不能被工具完成解除 | 同一调用在不同关联分区里查找 | 自动模式按会话和轮次固定关联分区，兼容唯一旧分区；有歧义时不猜测 |

同一会话可同时保留多个待处理请求，列表显示最新的一个。解决它后显示仍未解决的请求。计数仍表示会话数量。新轮次、明确的无请求 ID 恢复和终止事件清除该轮请求集合。已查看状态仍按会话管理。

## 消息覆盖

| 输入 | 行为 | 验证边界 |
|---|---|---|
| UserPromptSubmit | 开始新轮次 | 已有真实记录及自动测试 |
| PermissionRequest | 待确认 | 有工具 ID 时直接匹配；没有 ID 时仅关联唯一活动调用 |
| request_user_input 的 Pre / Post | 待回答 / 匹配恢复 | 已有真实 CLI 记录及回归测试 |
| request_user_input_async 的 Pre / Post | 待回答 / 忽略立即返回 | 已有真实记录，工具返回不代表用户回答 |
| 普通工具 Pre / 带 ID 的 Post | 记录调用 / 仅解除匹配请求 | 不把工具活动当作整个会话已恢复 |
| Stop / Interrupt | 本轮结束 / 已停止 | 已有真实记录及自动测试 |
| notify agent-turn-complete | 本轮结束 | argv 格式单独解析，自动测试覆盖 |
| 共享服务 completed / interrupted / failed | 修正对应轮次终态 | 只读轮次元数据，不补播历史修正 |
| SessionStart / SubagentStop | 不改变父会话状态 | 启动会话不等于开始任务，子任务结束不等于父任务结束 |
| SessionEnd | 仅有有效 turn_id 时支持断线事件 | 默认不注册，缺少轮次不能安全归属 |
| StopFailure / PostToolUseFailure / Notification | 不映射 | 当前官方 Hook 列表没有建立这些消息的适配契约 |
| MCP elicitation / permissions server request | 尚无直接适配 | 本机协议有这些请求，尚未验证其 Hook 投递和解除方式 |
| 同一轮内异步回答 | 尚无专用解除映射 | 不能从工具活动或运行状态推断已回答 |

官方说明部分专用工具可绕过默认 Hook 路径，因此工具 Hooks 不构成完整事件流。工具名保持精确匹配，不按 `input` 等子串猜测。[官方 Hooks 文档](https://learn.chatgpt.com/docs/hooks#tool-coverage)。

## 验证与保留边界

`PendingRequestTests` 覆盖请求交叠、完成先到、旧状态迁移、重启、来源合并和终态清理。`MessageIntakeTests` 使用真实 AppModel 和音频播放器验证批次语音及提醒身份。桥接测试执行真实 main、SQLite 和事件文件路径，只替换进程来源检测以复现检测失败。

`scripts/verify_runtime.py` 通过打包应用验证异步问题、交叠审批、重启、迟到审批和来源迁移。输入是合成事件，不等于对所有客户端完成了真实协议验收。本轮失败与修复后的输出保存在 `.audit/message-audit/`。整套测试通过 161 项 Swift 和 69 项 Python 测试，固定副本的打包应用通过 13 项运行检查。独立同模型复查额外通过 480 次请求交错、来源迁移和持久化比较，未发现新的阻断问题。已重启本机应用并核对其可执行文件和桥接脚本与验证产物一致。

仍要求新轮次有明确 started，避免迟到的未知轮次覆盖当前任务。不同待处理请求任意乱序到达尚不保证全序恢复。缺工具 ID 或多候选审批仍保留降级等待，不任意解除。

重跑：

```sh
./script/test.sh
./script/build_and_run.sh --build
python3 scripts/verify_runtime.py --check-speech --output .audit/message-audit/runtime.json
```

本次按 Model the Domain 把请求集合留在状态层，按 Laziness Protocol 保持公开 UI 模型不变，按 Build the Lever 扩展可重跑的运行检查，按 Prove It Works 验证打包应用及当前安装。跨模型审查不可用，不能将同模型独立复查描述为跨模型验证。
