# 发布 Codex Signal

## 版本

- `VERSION`：三段式版本号，如 `0.1.0`，写入 `CFBundleShortVersionString`。
- `BUILD_NUMBER`：递增正整数，如 `1`，写入 `CFBundleVersion`。
- Git 标签：`v` 加 `VERSION`，如 `v0.1.0`。
- 发布资产：`CodexSignal-<VERSION>-universal.dmg`、同名 ZIP 和 `SHA256SUMS.txt`。

每次发布前更新版本文件、README 版本入口与 CHANGELOG，并提交所有源码及发布脚本变更。即使只修复同一版本的构建，也应递增 Build；已发布的版本使用新版本号和标签。

## 本地构建和验证

发布前默认执行最小回归测试。先检查本次发布相对上一发布标签的差异，再选择改动及直接受影响行为的测试。只改文档或版本号时，跳过功能测试；版本号变更仍检查最终包的版本信息。

Swift 可按套件或用例筛选，筛选模式只运行匹配的 Swift 测试，不运行 Python 测试。没有匹配用例时脚本失败。示例：

```sh
./script/test.sh --filter 'AppModelTests|SessionNavigatorTests'
./script/test.sh --filter 'AppModelTests/openingAndFilteringSelectNewestAtBottom'
```

按实际影响范围选择以下测试；同一行中的套件也可继续缩小到相关用例：

| 改动范围 | 回归入口 |
| --- | --- |
| 会话状态、请求、持久化或来源 | 对应的 `SessionStoreTests`、`PendingRequestTests`、`RuntimeStatusTests`、`SessionMetadataTests`、`SessionSourceTests`；跨到提醒时加相关 `AppModelTests` 或 `MessageIntakeTests` 用例 |
| 列表、筛选、导航或提醒 | 对应的 `AppModelTests`、`SessionNavigatorTests`、`IslandNoticeTests`、`MessageIntakeTests` 用例 |
| 窗口、浮层或布局 | `IslandPanelTests`、`IslandLayoutTests` 的相关用例；过程检查见 [排查手册](playbooks/README.md) |
| 伙伴素材、动画或语音 | 对应的 `MascotAnimationTests`、`VoicePolicyTests` 用例 |
| Hooks 配置、桥接或请求关联 | `python3 scripts/test_configure_hooks.py`、`python3 scripts/test_bridge.py`、`python3 scripts/test_correlation.py` 中受影响的测试文件；接入生命周期变更加相关 `CodexConnectionTests` 用例 |
| 自动更新 | 相关 `UpdateTests` 用例；安装器变更运行 `python3 scripts/test_update_installer.py` |

仅在用户明确要求，或跨模块改动无法确定影响范围时运行全量 `./script/test.sh`，并说明原因。记录本次选择的测试、结果和未验证项。

回归通过后构建最终发布包。`release.sh` 只构建和打包，不自动运行测试：

```sh
./script/release.sh
lipo -archs dist/CodexSignal.app/Contents/MacOS/CodexSignal
codesign --verify --deep --strict dist/CodexSignal.app
```

发布脚本需要 macOS 工具链，分别构建 arm64 与 x86_64。运行验证只证明当前主机上的应用行为；跨架构编译不等于另一架构的实机验证。

另需将 ZIP 解压到临时目录验证其签名和启动，并挂载 DMG 检查应用和“应用程序”快捷方式。对外发布的文件必须来自最终提交中的源码。

启动最终包，确认设置中的版本及构建号。图标、资源或“关于”变更时，再检查对应图标、信息与第三方许可入口。事件接收、提醒、语音或启动恢复变更时，运行隔离的打包运行回归：

```sh
python3 scripts/verify_runtime.py --check-speech
```

## 上传 GitHub Release

确认 `main` 工作区干净、检查通过后：

```sh
git push origin main
git tag -a "v$(cat VERSION)" -m "Codex Signal $(cat VERSION)"
git push origin "v$(cat VERSION)"
gh release create "v$(cat VERSION)" \
  dist/releases/"CodexSignal-$(cat VERSION)-universal.dmg" \
  dist/releases/"CodexSignal-$(cat VERSION)-universal.zip" \
  dist/releases/SHA256SUMS.txt \
  --verify-tag --title "Codex Signal $(cat VERSION)" \
  --notes-file docs/releases/"v$(cat VERSION).md"
```

发布前创建对应的 `docs/releases/v<版本>.md`。首版发布说明已包含安装、接入与签名状态。

## 签名状态

当前脚本使用 `codesign --sign -` 进行 ad-hoc 签名，验证包内文件完整性。没有 Developer ID 签名或 Apple 公证。DMG 和 ZIP 同样没有 Developer ID 签名。

未来使用 Developer ID 发布时，需在打包前配置适用的 hardened runtime 和 Apple Events 权限，完成 Developer ID 签名、`notarytool` 公证与 stapling，并再次验证最终下载包。不要将签名证书、私钥或公证凭据提交到仓库。
