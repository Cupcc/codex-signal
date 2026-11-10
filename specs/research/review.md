# 独立代码审查

目标是以 agents team 完成先规格、再实现、再验收的 Codex Signal。此审查覆盖 Sources、scripts、script、Package.swift 与规格的一致性，不启动原生窗口，不操作用户 Codex 配置。

当前结论为 PASS，范围限于下面的代码审查与无窗口复验。本页所列 P1 已由主代理修复。真实原生交互、真实来源接入和多进程启动门禁仍需主代理的运行证据。

## 已发现并修复的问题

| 问题 | 原行为 | 修复与复验 |
|---|---|---|
| P1，积压分批顺序错误 | AppModel 先按随机 UUID 文件名取 200 条，再按 occurredAt 排序。第 201 条若是新回合 started，则同一回合的 question 可能先被拒绝并删除，最终停在 running | 改为全队列解码和排序后取批次。真实 AppModel 的 201 文件复验由 running 变为 question，inbox 均为空 |
| P1，启动积压补播 | 初始化的 silent 只处理第一批，余下历史在定时器里按新消息播报 | 启动时记录全部 startupFiles，消费时按文件身份静音。已静态核对覆盖后续批次，不以时间戳猜测历史 |
| P1，多实例覆盖状态 | 两个 AppModel 各持旧快照，先消费并删除队列的状态可被另一个实例覆盖 | AppMain 在创建模型前按 data-dir 获取 Darwin flock 排他锁。旧路径复现了已消费状态 1 行变 0 行。新锁已静态核对，真实双进程检查交主代理 |

上述第一和第二项共享 intake 分批根因，合并为一个修复单元。没有修改应用代码。修复由主代理执行。

## 实际执行的检查

运行 `python3 scripts/test_bridge.py`，14 项通过。覆盖标准事件验证、Hook stdin、notify argv、并发原子写、隐私字段、未知事件、符号链接目录和配置文件保持不变。

复验程序已归档于 `.audit/review/Reproduce.swift`。它以实际 SignalCore 编译对象链接实际 AppModel 和 SpeechController 源码，未启动 NSApplication 或窗口。旧版结果位于 `.audit/review/before.txt`，修复版结果位于 `.audit/review/after.txt`。执行 `./.audit/review/run.sh` 可对当前源代码重跑。脚本在独立临时目录构建，不启动应用，不读真实会话。旧版输出是修复前的实测记录，脚本默认重跑当前版本，不自动回退源代码。

关键输出如下。

```text
旧版
Expected question, actual running
Remaining inbox files 0
New writer sessions before stale write 1
Disk sessions after stale writer action 0
Shared inbox remaining 0

修复版
Expected question, actual question
Remaining inbox files 0
```

这个临时程序直接构造两个模型，用于证明旧设计的共享状态风险。它绕过 AppMain，因此不能验证后来增加的进程锁，也不能用它声称进程锁失效。

## 注释检查

删除数为 0，恢复数为 0，MUST KILL 为 0。保留 Coucou 的来源与 MIT 署名。Package.swift 的 tools-version 和 shell shebang 是工具指令。范围内没有叙述性代码注释、正确性 lint suppression 或待编码的约束注释。

## 审计记录

审查时 `.audit/decisions.tsv` 有四个数据行。首行手工时间不准确，第二行已追加纠正。架构与接口证据路径存在，内容支持其决策。审查时尚未记录本次缺陷与修复结果，主代理应在交付前追加对应结果与证据。

当前没有可读取的完整会话 transcript。证据核对以继承的会话摘要、现存文件和本代理实际命令为限。不能声称完成逐行 transcript 审计。评审模型沿用 inherit-parent 配置，本次是独立代理审查，不是跨模型审查。

Prove It Works 原则使审查用真实模型复现状态丢失，并明确区分源码检查、无窗口复验和原生运行证据。

## Attention

reviewed by inherit-parent 独立代理。

- 双进程启动门禁仍需实际启动证据。
- 真实 CLI、桌面事件、硬件刘海、多屏、锁屏和声音听感不在本代理的运行范围。
- 审计记录应补入本次失败与修复，保留首行时间纠正记录。
