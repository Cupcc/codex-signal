# Codex Signal 工作流程

> 本文记录最初的本地实现流程。当前版本已按用户要求建立公开 GitHub 仓库并发布；本文中“不创建提交或远程”的描述仅适用于当时的交付范围。当前发布流程见 [发布指南](../docs/RELEASING.md)。

目标是将已选 B 会话伙伴岛设计实现为可运行的 macOS 应用。先写规格，再构建，最后独立验收。

## 执行清单

- [x] Read the Principles section of the poteto-mode skill.
- [x] Phase A: Frame
- [x] Phase B: Design the workflow
- [x] Phase C: Run the loop
- [x] Phase D: Keep the audit trail
- [x] Phase E: Verify and hand back

## 当前分工

主协调者负责规格定稿、集成和交付。探索阶段分为上游架构、接入证据、验收设计三条独立只读任务。实现任务在接口规格冻结后按文件所有权分工。验收由未实现对应模块的代理负责。

架构比较步骤为 Ground、Sketch、Agree、Implement、Scrap。Agree 默认不等待人工批准。Scrap 仅在实现证据推翻架构时执行。

并行覆盖步骤为 Frame、Fan out、Aggregate、Report。架构候选比较步骤为 Frame、Fan out、Cross-judge、Pick、Graft、Verify。当前 pstack 模型角色均为 inherit-parent，独立评审不代表跨模型评审。严格要求另一模型家族的裁判跳过并记录。

## 门禁

1. 阅读现有设计与实际接入代码，明确实现范围和未知能力。
2. 先完成产品规格、模块契约、验收矩阵和架构选择。
3. 构建最小可运行产物，先验证事件和状态，再接 UI 与声音。
4. 运行自动测试、事件回放、真实应用交互。区分模拟验证与真实 Codex 事件。
5. 独立审查问题，修复后复验，交付运行命令和未验证项。

每一步记录证据。不能用构建成功替代产品验收。工作区当前没有 Git 仓库，不创建远程 PR，不发布安装服务。

## 吞吐检查点

范围约为 3 个产品模块和 1 组构建验收脚本。关键路径是冻结事件契约、核心可编译、原生集成、独立验收。核心状态、UI 和桥接使用独占目录并行，主代理单独负责 AppModel、语音和打包，避免共享文件冲突。构建命令由主代理串行运行；代理测试使用独立 scratch-path。每个模块先报实际构建或测试证据，再进入集成。

初始基线是只有静态设计，无 Package.swift、无可运行应用。已初始化本地 Git，仅用于跟踪变更，不创建提交或远程 PR。依照 Foundational Thinking 先写事件数据结构。依照 Model the Domain 用状态枚举及独立 seen。依照 Build the Lever 交付可重跑的 build/replay/verify 脚本。依照 Prove It Works 分开记录真实 UI、模拟输入和真实来源。

## 本轮结果

先规格后实现的顺序已执行。三路调研、三路实现、独立代码审查和打包应用验收均有产物。23 项 Swift 测试、14 项桥测试、7 项真实 .app 运行检查通过。原生交互通过 CUA 实际操作。真实 Codex 来源、完整硬件组合和听感保留为后续门禁，不因本地闭环通过而自动放行。

当前单次交付完成到本地 0.1 工程版本。完整产品接入仍以 VERIFICATION.md 的未验证行作为后续队列。

## 原则与具体选择

| 原则 | 改变的选择 |
|---|---|
| Foundational Thinking | 先冻结标准事件与模块契约，再分配实现 |
| Model the Domain | 用 phase 枚举和独立 seen，查看不解除审批 |
| Separate Before Serializing Shared State | 代理独占文件，桥每事件独立文件，应用单实例写状态 |
| Sequence work into verifiable units | 先模块测试，再打包应用，再原生交互及复验 |
| Build the Lever | 交付 test.sh、verify_runtime.py 与审查复现脚本 |
| Prove It Works | 隐藏源码资源并运行复制后的 .app，区分模拟与真实来源 |

## 真实接入增量

用户追加真实测试后，已安装全局事件接收 Hooks 并通过官方 CLI 界面信任。实测发现审批输入缺工具 ID、共享 daemon 缺客户端身份，分别补充调用关联和 unknown 来源。SQLite 锁冲突导致错关联的问题经独立代理复现并修复。真实 CLI 的开始、结束、中断、审批、提问及两种等待解除已通过；默认共享服务也已通过真实开始/结束验证。此次 56 项自动测试与 7 项隔离打包运行检查通过，最终独立审查无阻断项。完整证据与桌面端限制见 [真实接入验收](LIVE-VERIFICATION.md)。
