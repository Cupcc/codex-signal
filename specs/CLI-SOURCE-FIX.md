# CLI 来源识别与 Ghostty 跳转

## 问题与依据

共享 app-server 由 launchd 托管，Hook 的祖先链没有真正的 TUI 客户端。旧逻辑因此把 CLI 记为 unknown，随后走桌面端深链接。本机按会话 ID 只读查询 `state_5.sqlite.threads`，确认这批会话的 `source=vscode`、`originator=codex-tui`。`vscode` 不能用于区分桌面和 CLI；`originator` 表示创建来源，不代表以后每次恢复会话的客户端。

现在直接进程证据优先，共享服务才补查精确 ID 的 `originator`。只接受实测的 `codex-tui` 映射；陌生值保持 unknown。未知来源的桌面打开回退按用户要求保留。读取不涉及 prompt、preview 或 rollout，也不修改 Codex 数据库。

历史 unknown 记录自动迁移到 CLI，保留阶段、请求、时间、已查看、关闭状态和去重信息。新事件识别成功时立即合并；暂时读不到来源的事件沿用唯一已有身份。已明确区分的 CLI/desktop 记录保持隔离。共享服务的请求关联仍沿用原来的 transport 分区，避免更新期间切断 Pre/Permission/Post 的关联。不会把 daemon 的 TTY 或继承的 TERM_PROGRAM 当成客户端终端。

## Ghostty 主操作

用户确认主要使用 Ghostty，并要求主操作回到 tab，而非复制命令：

- 有受支持 TTY 时继续按 TTY 定位。
- 缺 TTY 时主按钮仍为“定位 Ghostty”。读取活跃 `codex` 进程的 TTY，匹配 Ghostty surface 的完整标题和这些 TTY，仅在唯一匹配时调用 `focus`。不按项目名或标题子串猜测，不输入任何命令。
- 标题候选兼容默认 `activity + thread-name + project-name`、只显示会话名、审批闪烁和录音标记，采用 Codex 的 48/24 字素截断规则。已有同名会话、多个同名 surface、缺少标题或无匹配时均不聚焦。
- 定位失败明确提示，不自动复制内容或打开桌面端。恢复命令保留为单独的备用操作。

完整标题匹配是缺 TTY 时的兼容路径，不能证明历史创建 tab 的不可变身份；用户自定义标题格式、改名尚未同步、同名/截断碰撞、tmux、已关闭 tab 和 VS Code 集成终端不在此路径的成功保证内。不会把匹配失败宣称为定位成功。

标题规则核对了 [Codex 标题组合](https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget/status_surfaces.rs)、[分隔规则](https://github.com/openai/codex/blob/main/codex-rs/tui/src/bottom_pane/title_setup.rs)、[审批标题](https://github.com/openai/codex/blob/main/codex-rs/tui/src/bottom_pane/action_required_title.rs)。Ghostty `name`、`tty`、`focus` 来自本机安装的 `Ghostty.sdef`。

## 验证

回归覆盖来源识别、只读 SQL 精确匹配/锁/旧 schema、迁移及重启、请求关联不断裂、未知来源回退不变、CLI 主操作、标题候选与注入拒绝、重复候选拒绝和 AppleScript 编译。80 项 Swift、27 项桥测试、16 项请求关联测试通过；应用构建、签名校验和启动通过。真实状态中 15 条记录均为 CLI，无重复线程。

用户补充使用 `terminal_title = ["spinner", "thread"]`，并亲自点击确认成功定位到对应 Ghostty tab。该模式已包含在完整标题候选中：`thread` 优先采用 `thread.name`，暂无名称时 Codex 回退 UUID。当前 15 条记录的标题均与 `session_index.thread_name` 和数据库 `threads.name` 相同；数据库回退也修正为优先 name、其次 title，并兼容旧 schema。


## 2026-11-10：通用终端与操作提示

主操作统一显示“打开会话”，成功反馈“已打开”。打开失败使用原有按钮／行旁浮层，带提示图标并自动消失；不写入底部 statusNotice，不改变列表高度。状态保存失败等持久错误仍保留在底部，短暂操作反馈不会覆盖它们。

缺 TTY 的路径不再绑定 Ghostty：先依据 terminalBundleID 限定原终端；没有来源信息时查询当前运行的 Terminal、iTerm2、Ghostty。所有查询均只读，汇总结果后只有唯一候选才执行目标终端的打开操作。多个应用同时出现同名候选也拒绝跳转。已知但暂未适配的终端明确提示，不误开 Ghostty。

Terminal 查询每个 tab 的 custom title/tty；iTerm2 查询各窗口、标签页下每个 session 的 name/tty；Ghostty 查询全部 surface 的 name/tty。命中后仍复用各应用原有按 TTY 打开的适配器，不输入命令。iTerm2 接口依据其[官方 AppleScript 文档](https://iterm2.com/documentation-scripting.html)，Terminal 接口依据本机 Terminal.sdef。

验证：84 项 Swift、27 项桥测试、16 项关联测试通过，覆盖关闭标签页的临时反馈、持久错误保留、来源选择、跨应用候选冲突及无匹配。本机已安装终端的查询和打开脚本完成编译检查；iTerm2 未安装，未做其实际标签页切换验收。


### 首选终端

设置新增“首选终端”：自动、Terminal、iTerm2、Ghostty。默认自动，旧设置文件及未知选项兼容回退为自动。选项即时保存，调整声音或保留天数不会覆盖终端偏好。

已知原终端／TTY 的会话继续返回原标签页。需要跨终端查找时先查询首选终端，唯一命中即返回，不触发其他应用的查询或权限请求；首选终端无匹配或未运行时，回退其余运行中的终端并保留唯一性检查。首选终端出现重名或权限错误时明确反馈，不将错误隐藏为其他应用的打开成功。

验证：89 项 Swift 和 43 项 Python 测试通过，新增覆盖优先命中、不重复查找、未运行／未找到回退、重名和权限失败、已知来源优先以及设置保存和重启恢复。
