#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
CONFIGURATION=debug
UNIVERSAL=false
while test "$#" -gt 0; do
  case "$1" in
    --release) CONFIGURATION=release ;;
    --universal) UNIVERSAL=true ;;
    *) echo "usage: $0 [--release] [--universal]" >&2; exit 2 ;;
  esac
  shift
done

VERSION="$(tr -d '\r\n' < VERSION)"
BUILD_NUMBER="$(tr -d '\r\n' < BUILD_NUMBER)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "VERSION must be X.Y.Z and BUILD_NUMBER must be a positive integer." >&2
  exit 2
fi

if $UNIVERSAL; then
  swift build -c "$CONFIGURATION" --triple arm64-apple-macosx14.0
  ARM_BIN_DIR="$(swift build -c "$CONFIGURATION" --triple arm64-apple-macosx14.0 --show-bin-path)"
  swift build -c "$CONFIGURATION" --triple x86_64-apple-macosx14.0
  INTEL_BIN_DIR="$(swift build -c "$CONFIGURATION" --triple x86_64-apple-macosx14.0 --show-bin-path)"
  BIN_DIR="$ARM_BIN_DIR"
else
  swift build -c "$CONFIGURATION"
  BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
fi

APP="$ROOT_DIR/dist/CodexSignal.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Bridge"
if $UNIVERSAL; then
  lipo -create "$ARM_BIN_DIR/CodexSignal" "$INTEL_BIN_DIR/CodexSignal" -output "$APP/Contents/MacOS/CodexSignal"
else
  cp "$BIN_DIR/CodexSignal" "$APP/Contents/MacOS/CodexSignal"
fi
for RESOURCE in "$BIN_DIR"/*.bundle; do
  if test -d "$RESOURCE"; then
    ditto "$RESOURCE" "$APP/Contents/Resources/$(basename "$RESOURCE")"
  fi
done
cp scripts/signal_bridge.py scripts/request_correlation.py "$APP/Contents/Resources/Bridge/"
ditto ThirdParty "$APP/Contents/Resources/ThirdParty"
cp VERSION BUILD_NUMBER "$APP/Contents/Resources/"
cp Sources/SignalApp/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexSignal</string>
<key>CFBundleIdentifier</key><string>io.github.cupcc.CodexSignal</string>
<key>CFBundleName</key><string>Codex Signal</string>
<key>CFBundleDisplayName</key><string>Codex Signal</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSUIElement</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Codex Signal contributors</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppleEventsUsageDescription</key><string>用于定位终端标签页，或新建标签页并填入恢复命令，等待你按回车执行。</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built Codex Signal $VERSION ($BUILD_NUMBER): $APP"
