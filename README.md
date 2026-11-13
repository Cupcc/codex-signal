<img src="design/assets/app-icon.png" alt="Codex Signal 应用图标" width="96">

# Codex Signal

让 Codex 和 Claude Code 的运行、审批和提问状态，留在屏幕顶部。

Codex Signal 是一个原生 macOS 会话提醒工具，支持 Codex 与 Claude Code：收起时是一只蓝色伙伴，展开后查看多个会话，并回到需要处理的任务。界面和语音提醒均为中文。

[下载最新版](https://github.com/Cupcc/codex-signal/releases/latest) · [接入指南](specs/CONNECT.md) · [更新记录](CHANGELOG.md)

<img src="exports/mascot-motion/mascot-six-states.gif" alt="蓝色伙伴的运行中、空闲、待确认、待回答、待查看和运行失败六种动效" width="720">

[标准与迷你版动效](exports/mascot-motion/README.md)直接使用应用当前的角色图层和动画轨道导出。

## 功能

- **会话状态**：运行中、待确认、待回答、待查看、停止与异常；支持“全部 / 待处理 / 待查看”筛选。完成结果会保留待查看标记，直到标记已查看、关闭提醒或按保留期限清理。
- **返回会话**：打开 Codex 桌面会话，或定位 Terminal、iTerm2、Ghostty 中对应的 CLI 或 Claude Code 标签页。定位失败时，在可用终端的新标签页填入恢复命令（`codex resume` 或 `claude --resume`），按回车继续；失败时保留复制的命令。可设置首选终端。
- **语音提醒**：立即播放对应状态的内置中文音频，播放期间到达的提醒按顺序播放；支持静音、安静时段和锁屏暂停。音频位于 `Sources/SignalApp/Resources/Audio`，Codex 使用 `codex-*.mp3`，Claude Code 使用 `claude-*.mp3`；设置中的「预览提醒」播放 `codex-approval.mp3`。
- **轻量交互**：方向键选择、Return 执行主动作、Escape 收起；查看历史时保留滚动位置。
- **提醒管理**：关闭单条提醒，或使用“全部已读”清除已结束及异常提醒，保留运行中、待确认和待回答会话；支持按 7、15、30 天自动清理，重启后保留状态。
- **灵动岛提示**：审批、提问、结束与异常会短暂展开，6 秒后自动收回；支持合并提醒、独立开关和设置内预览。静音时仍可看到提示。
- **应用更新**：默认启动时及每 6 小时检查 GitHub 正式版，自动下载并校验，点击“重启并更新”安装。设置和菜单栏右键菜单始终提供 GitHub 手动下载入口。
- **自动接入**：安装或升级后的首次启动检查 Codex 和 Claude Code 的 Hooks，普通启动不检查；设置中可分别强制重新配置。Codex 首次使用仍需审阅 Hooks；Claude Code 自动生效。
- **产品信息**：Finder 和“关于”窗口使用蓝色伙伴图标；设置底部显示版本与构建号，并提供“关于”按钮。“关于”提供项目主页、问题反馈和第三方许可入口。设置中提供退出应用入口，支持 ⌘Q；也可在设置中开启开机启动。
- **原生动效**：折叠伙伴汇总全部会话状态，显示运行数量；展开高度适配列表内容，收起与展开时保持顶部居中。伙伴随状态变化，支持系统“减少动态效果”设置。

关闭提醒不会取消任务，也不会代替回答或审批。“本轮结束”只表示运行结束，不代表测试成功。

## 安装

需要 **macOS 14 或更新版本**。下载包为 Universal，包含 Apple Silicon 和 Intel 架构；本轮运行验证在 Apple Silicon 上完成。

1. 从 [Releases](https://github.com/Cupcc/codex-signal/releases/latest) 下载 DMG，打开后将 `CodexSignal.app` 拖入“应用程序”。也可下载 ZIP 后解压安装。
2. 打开应用，点击屏幕顶部的伙伴或菜单栏的 `◈ Signal` 展开列表。右键菜单栏可检查更新、手动下载或查看版本；退出应用请在设置中操作。
3. 应用自动配置接入。在 Codex 的 Hooks 设置中审阅并信任后，开启新会话。只看效果可在终端运行：

```sh
open -n /Applications/CodexSignal.app --args --demo
```

**当前版本使用 ad-hoc 签名，尚未通过 Apple 公证。** 首次打开若被系统阻止，请在“系统设置 → 隐私与安全性”中查看“仍要打开”。若系统提示应用损坏，确认下载来源和 SHA-256 后，可仅移除该应用的隔离标记再打开：

```sh
xattr -dr com.apple.quarantine /Applications/CodexSignal.app
```

自动更新要求应用所在目录可写；磁盘映像或系统隔离运行位置中的应用需先移至“应用程序”。更新下载完成后不会自行退出，需点击“重启并更新”。替换失败会尝试恢复旧版，并打开 [GitHub 手动下载页](https://github.com/Cupcc/codex-signal/releases/latest)。安装后会在应用旁保留隐藏的 `.CodexSignal-update-…-previous.app` 旧版备份，可在确认新版正常后删除。

Release 附带 `SHA256SUMS.txt`。将它与下载包放在同一目录后，可检查对应文件：

```sh
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```

## 接入 Codex

安装、重新安装或升级后的首次启动会检测 Python 3.9+，将桥接脚本安装到应用数据目录，并检查用户级 `hooks.json`：同版本不写文件，缺项才添加，桥接内容更新才原位更新命令。检查结果随本次安装记录保存，普通启动只恢复记录，不检测 Python、不检查 Hooks。移动应用不影响已安装的桥接。

Codex 要求首次审阅 Hooks：桌面端打开“设置 → Hooks”，CLI 运行 `/hooks`。审阅并信任后开启新会话。应用先显示“已配置 · 等待事件”，收到事件后显示“已接收事件”。[官方 Hooks 说明](https://learn.chatgpt.com/docs/hooks)

点击“一键配置”“重新配置”或“重试”会强制重装桥接、重建 Codex Signal 的 Hooks，恢复本应用接收器的默认设置；其他 Hooks 和 `notify` 会保留。实际修改前保存原文件备份。检查失败或中断后，普通启动不会自动重试，可点击“重试”恢复。未检测到 Python 时会提供安装入口。演示模式不修改 Codex 配置。

配置位置、开发回放和来源识别见 [接入指南](specs/CONNECT.md)。

## 接入 Claude Code

同一次检查也处理 Claude Code：检测到 `~/.claude`（或 `CLAUDE_CONFIG_DIR`）时，将本应用的 Hooks 合并进其中的 `settings.json`，保留其他设置和 Hooks，修改前保存备份。未检测到时不创建目录，设置中显示“未检测到”，可点击“一键配置”。Claude Code 会自动载入新的 Hooks，无需审阅，正在运行的会话也会开始上报。

列表中的来源显示为“Claude Code”。打开会话时回到原终端标签页；找不到时在新标签页填入 `claude --resume` 命令。详情见 [接入指南](specs/CONNECT.md#接入-claude-code)。

### 当前接入边界

CLI 的开始、结束、审批、提问、中断和等待解除已有本地真实接入记录。桌面端完整事件覆盖、所有终端组合与 Intel 实机运行尚未完成验证。无法唯一匹配的终端会话会显示反馈，不会随意打开同名标签页。

内置桥不会从一次工具报错推断整轮失败；提问提醒取决于客户端是否发出相应 Hook。Claude Code 没有中断 Hook：按 Esc 中断或拒绝授权后，状态保持到 Claude Code 报告输入空闲（约 60 秒）、会话结束或下一次提问。详情见 [真实接入记录](specs/LIVE-VERIFICATION.md) 与 [CLI 来源和导航](specs/CLI-SOURCE-FIX.md)。

共享服务会话每 5 秒核对一次轮次状态，补回漏收的结束、中断或失败事件；修正不播报，也不会重新打开已关闭的提醒。独立 CLI 仍依赖 Hooks。范围与依据见 [运行状态修复记录](specs/RUNTIME-STATUS-FIX.md)。

## 本地数据

状态、设置与事件保存在 `~/Library/Application Support/Codex Signal`。演示模式使用独立临时目录。右键菜单栏选择“打开数据目录”可查看本地文件。

事件桥只写入本机；应用没有遥测或远程服务。保存的元数据可包含会话标题、项目名、工作目录和终端标识，因此仍可能包含业务信息；不保存提示正文或工具输入正文。调用关联使用标识和摘要。Codex 会话标题与来源由本地 Codex 元数据只读查询补全；Claude Code 只使用 Hook 提供的自定义标题，不读取对话记录。

## 开发

需要 Xcode 或 Command Line Tools、Swift 5.9+，以及用于测试和桥接的 Python 3。测试使用 Swift Testing，需要 Swift 6+。没有第三方运行时包依赖。

```sh
git clone https://github.com/Cupcc/codex-signal.git
cd codex-signal
./script/build_and_run.sh          # 编译并重启
./script/build_and_run.sh --demo   # 演示模式
./script/test.sh --filter 'AppModelTests' # 按改动选择 Swift 回归测试
./script/test.sh                         # 全量 Swift 和 Python 测试，按需运行
```

产物位于 `dist/CodexSignal.app`。还支持 `--build`（只构建）、`--verify`（启动检查）、`--debug`、`--logs` 和 `--telemetry`。Codex 项目的 Run 按钮调用同一个构建运行脚本。安装 [just](https://just.systems/) 后，也可使用 `just dev`、`just test`、`just release` 等快捷命令。

应用图标沿用原创蓝色伙伴，由 `python3 scripts/build_app_icon.py` 重建 SVG、1024px PNG 和包含 16–1024px 尺寸的 `AppIcon.icns`。打包脚本将图标复制到 App 资源目录，并写入图标、应用类别、语言及版权信息。应用常驻菜单栏，不在 Dock 中显示。

验证打包应用：

```sh
python3 scripts/verify_runtime.py --check-speech
```

该检查使用临时目录和人工事件；语音检查预期保持安静。

窗口跳位、失焦和浮层关闭问题的排查步骤见 [排查手册](docs/playbooks/README.md)。[设置失焦后折叠跳位的记录](docs/playbooks/2026-11-10-popover-collapse.md) 包含无效尝试、关闭时序证据和回归验证。

## 构建发布包

版本由 [VERSION](VERSION) 和 [BUILD_NUMBER](BUILD_NUMBER) 统一管理。当前为 **0.7.0（Build 10）**，“关于 Codex Signal”中可查看。

```sh
./script/release.sh
```

自动更新读取 [GitHub Releases API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release) 的最新正式版，要求 `vX.Y.Z` 标签、`CodexSignal-X.Y.Z-universal.zip` 资源及 GitHub 提供的 `sha256:` digest。缺少资源或摘要时保留手动下载入口；发布新版本必须递增 `VERSION`。下载后验证 SHA-256、应用标识、版本、最低系统版本和代码签名完整性；当前 ad-hoc 签名不代表 Apple 公证或独立的发布者身份认证。

脚本分别编译 arm64 和 x86_64 的 Release 可执行文件，合并为 Universal 应用，打包资源、事件桥和第三方许可，完成 ad-hoc 签名与校验，生成：

```text
dist/releases/
├── CodexSignal-0.6.0-universal.dmg
├── CodexSignal-0.6.0-universal.zip
└── SHA256SUMS.txt
```

发布前默认按改动执行最小回归测试，并验证最终发布包。测试选择与发布操作见 [发布指南](docs/RELEASING.md)。

## 项目结构

| 目录 | 内容 |
| --- | --- |
| `Sources/SignalCore` | 事件、状态归约、会话元数据 |
| `Sources/SignalApp` | 原生窗口、列表、动效、语音与持久化 |
| `scripts` | Python 事件桥、回放与运行验证 |
| `script` | 构建、测试和发布入口 |
| `Tests` | Swift 测试 |
| `specs` | 产品规格、模块契约与历史验收记录 |
| `docs/playbooks` | 可复用的排查步骤与故障记录 |
| `design` | 设计源文件与历史静态稿 |

历史验收记录中的 `.audit/` 是开发机本地证据，不随仓库发布。设计稿只作为设计资料，应用能力以源码和当前接入边界为准。

## 致谢与第三方许可

会话提醒与导航方案参考 [CodeIsland](https://github.com/wxtsky/CodeIsland)；屏幕几何代码改编自 [Coucou](https://github.com/Louis-CFM/coucou)。相关 MIT 许可保留在 [ThirdParty](ThirdParty/README.md)，并随应用分发。原生应用使用原创蓝色角色，设计资料中的参考资产另有[来源说明](design/assets/ATTRIBUTION.md)。
