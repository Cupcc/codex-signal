# 关闭会话后仍显示运行中

2026-11-10，排查会话 `01a1c12d-f549-7352-9206-36801578066a`。

## 原因与证据

- Signal 持久化状态为 running，轮次为 `01a1c12e-6d56-7612-b9df-588f206aa8fb`。现存桥接诊断只有工具开始和结束记录，没有收到生命周期终止事件的证据。
- Codex 服务返回会话 notLoaded、该轮 interrupted；磁盘 `thread_history_1.sqlite` 的同一轮仍为 inProgress，completed_at 为空。单独读取历史数据库无法纠正这个实例。
- Signal 原先只靠 Hooks 改变状态，定时检查只更新标题和来源，重启后也会恢复旧 running。关闭客户端不保证产生已接入的终止 Hook；SessionEnd 默认未注册，因为可能不携带 turn_id。

## 参考项目

| 项目 | 对应设计 | 本次采用的原则 |
| --- | --- | --- |
| [CodeIsland：SessionProcessMonitor](https://github.com/wxtsky/CodeIsland/blob/03c77e9457f0adc56fa036caf4925e4a576b453b/Sources/CodeIsland/SessionProcessMonitor.swift) | 监听进程退出，并定期核对进程身份与存活状态 | 事件通知需要独立核对机制 |
| [notchi：NotchiStateMachine](https://github.com/sk-ruban/notchi/blob/e6f8b8a805cec31b5d3844d2ea8faa7a836ebc7e/notchi/notchi/Services/NotchiStateMachine.swift) | 核对 Codex 进程存活和归档、删除状态，通过正常结束路径清理 | 用可确认的终止事实修复状态 |
| [Coucou：PillSessionRegistry](https://github.com/Louis-CFM/coucou/blob/b1bc09de7f7c24a80bd8eca5729b8bee60f66402/NotchBuddy/Sources/App/PillSessionRegistry.swift) | 30 分钟静默取消 working，12 小时静默移除会话 | 静默清理可作兜底，但本次不采用固定超时，避免误判长时间任务 |

共享服务进程可以同时管理多个会话，因此不能根据该进程仍在运行推断每条会话仍在工作。当前实现直接读取该服务提供的轮次状态。Socket 传输为 WebSocket；协议形状由本机 0.167.0 的 `app-server generate-json-schema --experimental` 核验，查询没有启动、恢复、订阅或中断会话。

## 修复范围

仅核对来源已确认属于共享服务的会话。后台每 5 秒查询最近 20 轮的状态元数据，每次连接总时限 3 秒、单条消息上限 1 MiB。独立 CLI、未知来源、接口错误、连接失败和无匹配轮次均不推断终止。

核对结果按来源、会话和轮次精确匹配，不能覆盖已到达的新轮次、新 Hook 或新工具元数据。保留提醒的已读、关闭和排序信息，不播报历史修正；观察时间不写入事件时间，防止拒收尚在收件箱中的新轮次。

## 验证

回归覆盖缺失 Interrupt、三种终止结果、inProgress 与未知状态、轮次竞争、延迟到达的新轮次、提醒关闭状态、来源隔离、服务不可用及独立 CLI 排除。重新构建并启动应用后，上述真实会话的运行快照和持久化状态均自动变为 stopped；核对没有触发语音。
