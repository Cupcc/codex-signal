# 真实接入独立审查

目标是核对真实接入结果与代码、证据是否一致，避免把样例、共享服务或间接计数扩大为未验证的结论。

2026-11-09。结论为 PASS。未发现新的阻断性功能缺陷。两项文档精度建议已交给主代理处理。

throughput checkpoint: n/a, read-only investigation

## 范围与证据

本次读取 `scripts/signal_bridge.py`、`scripts/request_correlation.py`、`scripts/observe_live.py`、来源枚举和相关界面分支，以及 `specs/LIVE-VERIFICATION.md`。真实会话数据只读取 `.audit/live`。没有读取其他真实会话、全局配置或私有备份，没有重新构建或操作应用。

只读核对脚本统计出 23 份 event 元数据，其中 21 份标记 cli，2 份标记 unknown。它们只涉及验收文档指定的两个测试会话。所有 cli 状态快照及共享服务快照均为 `isDemo=false`。元数据没有保存 prompt、tool_input、tool_response、transcript_path 或回复正文的值。字段名称本身仍会保留。

本次按照 Prove It Works 原则直接比对保存的事件、状态快照和代码。此审查不是第二次实时执行，也不将保存的布尔结果称为独立重做的配置对比。

## 核对结果

| 项目 | 结果与具体依据 |
|---|---|
| 真实事件与样例边界 | PASS。限定证据采用两个测试会话的 Hook 元数据，快照关闭 demo。`LIVE-VERIFICATION.md` 将回放和真实结果分开，未以 replay 结果证明真实 CLI。 |
| 审批 ID 关联 | PASS。`event-908bdbae6c2a4fd39591783a34d33d7d.json` 保留原始 `toolUseIdPresent=false`，规范 requestId 为 `tool:exec-59ca812d-b9b9-447c-aa2a-5db642b83f79`。`event-902d949206314436813dc04e1d3c6c60.json` 的 PostToolUse 使用同一 requestId。`approval-fixed-transitions.jsonl` 记录 approval 后先 running 且 pending=false，再 completed。 |
| 提问 ID 关联 | PASS。`event-2dd08f2315964b028efc717bf21a3b87.json` 和 `event-2316a12f63dd4de1ae8d5ab2a8e79694.json` 使用相同 requestId。`question-transitions.jsonl` 记录 question 后先 running 且 pending=false，再 completed。 |
| 已查看与待处理 | PASS。`approval-ui.txt` 明确显示已查看、仍待确认和一项待处理，`cli-approval-viewed.json` 同时为 seen=true、pending=true。 |
| 共享服务来源 | PASS。共享会话的两个 event 均为 unknown，`shared-service-result.json` 的会话 ID 也使用 unknown 前缀。`classify_process` 不再把没有 Codex 桌面父应用的 app-server 判为 desktop。界面显示来源待识别并提供复制会话标识。 |
| notify 保留 | 有本轮比较记录。`config-preservation.json` 的 notifyUnchanged 和 nonTrustConfigUnchanged 均为 true，`installation.json` 记录私有备份位置。接收器自身没有配置写入路径。本审查按范围限制没有重新读取全局配置，不能将这项记录升级为第二次独立对比。 |
| 关联降级 | 静态核对通过。数据库按来源、会话、回合隔离，Post 保留 finished 墓碑，重复 Pre 不重新打开已完成调用。唯一未完成匹配才补 ID，Pre 写入失败时使用独立的不完整标记阻止该回合继续猜测关联。 |

## 结论边界

桌面专属测试仍为 NOT VERIFIED。共享服务 CLI 的接收结果不能证明桌面已验收。文档明确保留了这个限制。

`observe_live.py` 按指定来源及会话筛选状态，但 speechCount 来自整个应用。计数支持系统语音调用记录，不能证明实际声音听感。共享服务快照经过会话筛选，但保留了全局计数，不能把这些计数解释为该单条会话的累计数。

本轮没有重新执行完整回归套件，因此测试总数和构建结论仍由主代理提供的执行记录承担。

## 文档精度建议

审查时 `LIVE-VERIFICATION.md` 写了六项 Hook 在官方界面逐项查看并信任。实际操作记录是查看桥接命令后信任六项。建议表述为在官方 `/hooks` 界面查看桥接命令并信任六项。

审查时文档将系统语音调用和静音策略一同归于本轮计数证据。限定 live 目录直接支持调用及 Interrupt 不增加计数。静音策略应指向对应回归证据，或从本轮真实验收表述中去掉。
