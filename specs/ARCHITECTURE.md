# 架构选择

候选 A 分析直接 fork CodeIsland，候选 B 分析独立应用与薄事件桥。两者最终建议窄范围复用，报告见 research/architecture-a.md 和 research/architecture-b.md。

## 选择依据

| 标准 | 全量 fork | 独立 SwiftPM 与窄范围复用 |
|---|---|---|
| 保留 B 通知体验 | 需删除审批操作与多平台分支 | 原生列表直接按规格实现 |
| 启动副作用 | 上游默认自动安装配置并启动附加服务 | 只读 inbox 与自己的状态目录 |
| 状态可验证性 | 依赖大型 AppState 与历史兼容 | 纯 SessionStore 独立测试 |
| 本机可构建性 | Sparkle、Yams 及打包依赖 | 系统框架与 SwiftPM |
| 后续维护 | 上游功能丰富，合并范围大 | 功能少，事件覆盖需单独扩展 |

采用候选 B 的进程边界和数据模型。采用候选 A 调研的 Coucou 屏幕几何及 CodeIsland 非激活面板、独立静音状态参考。没有复制 Coucou 角色资产。独立模型家族裁判跳过，当前配置全部 inherit-parent。由主代理核对两个报告，实施后安排独立代理检查代码及产物。

状态只有 AppModel 一个写入者。外部进程各写自己的原子事件文件。SignalCore 不依赖 AppKit。UI 只读取投影并发送用户动作。SwiftPM 包不依赖上游仓库在线可用。

0.7.0 接入 Claude Code 时沿用同一边界：同一事件桥以 `--source claude` 写入同一收件目录，代理差异只在桥的 Hook 映射、接入配置、导航、语音与角色呈现中处理，SessionStore 的状态归约不分代理。

兼容成本是首版不继承上游全量实时发现和准确会话跳转。这个限制公开写入规格与界面，避免向用户承诺无法验证的能力。
