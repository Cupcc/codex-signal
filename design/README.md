# Codex Signal · 设计入口

以 **CodeIsland 的灵动岛与会话框架**为基础，加入 **Coucou 式圆润小玩偶**与中文系统语音。覆盖 Codex 桌面版和 CLI。

## 先看画面

- [蓝色 Codex 角色设计](ui/08-character.html)：五态动效、状态切换、暂停/重播与实际尺寸；[查看角色总览图](images/character.png)。

- [打开三版对比页](compare.html)：可并排比较、单张查看、切换到实际尺寸；无需联网。
- [A 伙伴接力](images/relay.png)：早期对照，突出一个任务。
- [B 会话伙伴岛](images/inbox.png)：**用户已选定**，多会话纵向排列、选中行就地展开。
- [C 项目泊位](images/dock.png)：历史对照，未采用。
- [关键状态图](images/states.png)：运行、结束、审批、提问、中断、无刘海与语音暂停。
- [三版并排总览](images/sheet.png)。

| 比较点 | A 伙伴接力 | B 会话伙伴岛 | C 项目泊位 |
|---|---|---|---|
| 信息重心 | 当前交接 | 全部会话 | 固定项目 |
| 展开宽度 | 552px | 700px | 792px |
| 角色尺寸 | 96px | 56px | 64px |
| 适用场景 | 后台等待，偶尔接手 | 多个短任务进出 | 少数长期项目并行 |
| 主要代价 | 看全局需再展开 | 占屏幕面积较大 | 项目多时需要溢出处理 |

**已选 B「会话伙伴岛」；用户明确不选 C。** A/C 仅作历史对照。新增 [会话伙伴岛关键场景](images/inbox-flows.png)，明确同项目多会话、新消息不抢走当前行、已查看未处理与长列表规则。[声音设置](images/settings.png) 继续沿用。

## 设计依据

- [角色动效与验证](MOTION.md)：五态节奏、后台暂停和减少动态效果。

- [产品与交互设计](DESIGN.md)：状态、提醒优先级、语音文案、合并去重、显示器、辅助功能及接入边界。
- [GitHub 项目参考分析](REFERENCE-ANALYSIS.md)：CodeIsland、Coucou、Notchi 的借鉴点和适用范围。
- [素材来源](assets/ATTRIBUTION.md)：原创圆润玩偶与 CodeIsland 经典角色的来源分开记录。
- [蓝色角色验证记录](CHARACTER-VERIFICATION.md)：本轮角色、缩放检查与独立评审。
- [验证记录](VERIFICATION.md)：渲染检查范围及尚未实现的部分。

## 交付性质

本轮为**设计说明、静态 UI 稿和离线比较工具**。三版画面采用同一组设计数据：API 服务等待审批、Atlas 网站本轮结束、设计系统正在检查组件。状态图展示不同时间点的状态，并非同时发生的真实消息。

HTML 内的产品按钮为静态视觉元素；未接入真实会话、系统语音、Hook 或原生窗口。角色动效已实现，可在角色页切换、重播和暂停；窗口与业务流程动画仍为设计规格。对比页的切换、缩放和选择由比较工具提供，选择不会自动修改项目文件。

未修改 Codex 配置，也未覆盖已有 notify 接收器。后续原生接入应从 CodeIsland 源工程迭代，并验证桌面版与 CLI 的真实事件来源。

## 可编辑源文件

`ui/01-relay.html`、`ui/02-inbox.html`、`ui/03-dock.html`、`ui/04-states.html`、`ui/05-settings.html`、`ui/06-dock-flows.html`（历史 C 场景）、`ui/07-inbox-flows.html`（当前 B 场景）是独立静态画板；依赖 `assets/toy-*.svg`，请保留相对目录。前三版视口为 1440×900，状态图与泊位场景图为 1440×1100，设置图为 1440×1000，B 场景图为 1440×1560。

蓝色括号伙伴由 `assets/build_toys.py` 生成，无外部依赖。直接运行 `python3 assets/build_toys.py` 可重建五个标准 SVG 与五个小尺寸 SVG。正式画面没有外部字体、跟踪脚本或第三方 CDN。
