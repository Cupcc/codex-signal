# 发布 Codex Signal

## 版本

- `VERSION`：三段式版本号，如 `0.1.0`，写入 `CFBundleShortVersionString`。
- `BUILD_NUMBER`：递增正整数，如 `1`，写入 `CFBundleVersion`。
- Git 标签：`v` 加 `VERSION`，如 `v0.1.0`。
- 发布资产：`CodexSignal-<VERSION>-universal.dmg`、同名 ZIP 和 `SHA256SUMS.txt`。

每次发布前更新版本文件、README 版本入口与 CHANGELOG，并提交所有源码及发布脚本变更。即使只修复同一版本的构建，也应递增 Build；已发布的版本使用新版本号和标签。

## 本地构建和验证

```sh
./script/test.sh
./script/release.sh
python3 scripts/verify_runtime.py --check-speech
lipo -archs dist/CodexSignal.app/Contents/MacOS/CodexSignal
codesign --verify --deep --strict dist/CodexSignal.app
```

发布脚本需要 macOS 工具链，分别构建 arm64 与 x86_64。运行验证只证明当前主机上的应用行为；跨架构编译不等于另一架构的实机验证。

另需将 ZIP 解压到临时目录验证其签名和启动，并挂载 DMG 检查应用和“应用程序”快捷方式。对外发布的文件必须来自最终提交中的源码。

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
