# 会话导航源码对比

本轮比较本地只读副本：CodeIsland `03c77e9457f0adc56fa036caf4925e4a576b453b`、Coucou `b1bc09de7f7c24a80bd8eca5729b8bee60f66402`。

CodeIsland 的 `Sources/CodeIsland/TerminalActivator.swift` 使用 `codex://threads/<UUID>` 打开桌面会话，并把链接交给正在运行的 Codex 安装副本。其 Terminal/iTerm 分支使用 TTY 选择标签，也有按目录标题等较弱匹配的回退。Coucou 的 `NotchBuddy/Sources/App/IslandViewContent.swift:openSessionApp` 仅激活来源应用，不能据此声称已经定位到会话。

本 app 的 `SessionNavigator` 采用精确 thread UUID 和 Terminal/iTerm TTY；没有移植目录名、窗口标题子串猜测。其他 CLI 来源复制 `codex resume '<UUID>'`，可用时带经过 shell 引用的 `cd -- '<cwd>'`，由用户粘贴执行。来源未知但有合法 UUID 时仍可直接请求 Codex 打开对应本地会话。

## 本机静态证据

- `/Applications/ChatGPT.app` 实际 bundle identifier 为 `com.openai.codex`，版本 `26.1103.60933`，Info.plist 注册 `codex` URL scheme。
- `app.asar/.vite/build/early-bootstrap.js` 含 `codex://threads/${...}` URL 构造。
- `app.asar/.vite/build/early-bootstrap-339-cb7e73ca5a71df7c.js` 的 `case "threads"` 返回 `kind: "localConversation"`，并将可选 hostId 交给后续导航。
- 本机 `codex resume --help` 明确接受 UUID 类型 SESSION_ID。

ASAR SHA-256：`a77588b2dcfa9b394d722dd8c2c8b13d3a09bacd49c839cc715245742dba6048`。REA 对一个 bootstrap 文件执行了静态分析；7 个未使用的 unpacked 原生依赖记录了打包完整性矛盾，继续保留为不可信字节，没有执行这些内容。静态 URL handler 观察不等于实际导航成功，最终需原生 UI 验证。

## 结果与限制

链接交付成功仅显示“已请求 Codex 打开此会话”。Terminal/iTerm 仅在脚本返回 `matched` 后显示已定位标签；自动化拒绝、超时、应用关闭、找不到 TTY 时明确报告并复制恢复命令。定位操作不会自动运行用户 shell 命令。

旧 TTY 被系统复用时仍可能指向后来打开的终端；当前没有 CLI PID 与进程启动时间联合验证。Ghostty、tmux、远程主机及其他终端未实现原标签定位，统一使用恢复命令。单元测试覆盖路由、UUID/TTY 注入拒绝和命令引用；自动化授权与实际标签切换须另做运行验收。

保留 [CodeIsland MIT 许可](../../ThirdParty/CodeIsland-LICENSE.txt)。


## Ghostty 增量核查（同日）

用户已确认桌面会话精确跳转成功。此前“Ghostty不支持定位”的范围判断更正：本机为Ghostty 1.4.0/build18457，安装包的 `Ghostty.sdef` 明确提供 terminal.tty、pid、id 和 focus。CodeIsland固定旧版本里“Ghostty没有tty”的注释已过时。

已增加 `com.mitchellh.ghostty` 导航分支，精确匹配TTY后调用focus；遍历全部surface覆盖后台tab和split。匹配不唯一/缺失则回退，且不单独调用activate（避免唤起quick terminal）。同版本源码中focus异步调度，成功文案保持“已请求”而不声称视觉切换已经完成。

官方证据：[1.4发布记录](https://ghostty.org/docs/install/release-notes/1-4-0)、[AppleScript接口](https://ghostty.org/docs/features/applescript)、[同版本focusSurface](https://github.com/ghostty-org/ghostty/blob/83fb95624/macos/Sources/Features/Terminal/BaseTerminalController.swift#L318)。

用户观察tab名称与会话title一致，符合[Codex终端标题输出](https://github.com/openai/codex/blob/main/codex-rs/tui/src/terminal_title.rs)及[标题组合](https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget/status_surfaces.rs)机制：thread-name来源是thread_name，默认可包含activity与project-name，thread名称片段最长48个grapheme。标题不是稳定唯一ID，不能仅凭同名宣称精确匹配。

实机验证边界：CUA明确拒绝访问Ghostty，未使用其他途径读取或控制其真实窗口。未更改自动化权限。当前Signal已存的5个会话没有TTY，其中4个source=unknown；新增路由不会凭空补齐这些历史记录。共享daemon的Hook祖先链缺客户端TTY问题仍存在，需另做可靠会话绑定，不能声称只新增导航分支就已覆盖这批现有CLI会话。tmux内部PTY和TTY复用问题也保持未解决。
