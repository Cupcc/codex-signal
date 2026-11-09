#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
if test "$#" -gt 0; then echo "usage: $0" >&2; exit 2; fi
VERSION="$(tr -d '\r\n' < VERSION)"
"$ROOT_DIR/script/build_app.sh" --release --universal
APP="$ROOT_DIR/dist/CodexSignal.app"
RELEASE_DIR="$ROOT_DIR/dist/releases"
NAME="CodexSignal-$VERSION-universal"
mkdir -p "$RELEASE_DIR"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-signal-release.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

# Exclude local metadata and resource forks from downloadable artifacts.
COPYFILE_DISABLE=1 ditto --norsrc --noextattr --keepParent -c -k "$APP" "$RELEASE_DIR/$NAME.zip"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP" "$STAGING_DIR/CodexSignal.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "Codex Signal $VERSION" -srcfolder "$STAGING_DIR" -format UDZO -ov "$RELEASE_DIR/$NAME.dmg"
cd "$RELEASE_DIR"
shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt
echo "Release artifacts: $RELEASE_DIR"
