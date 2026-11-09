#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
swift build
BIN_DIR="$(swift build --show-bin-path)"
EXPORT_BINARY="$(mktemp -t signal-gif-export)"
trap 'rm -f "$EXPORT_BINARY"' EXIT
swiftc -parse-as-library Sources/SignalApp/AnimatedMascot.swift Sources/SignalApp/MascotAnimation.swift \
  "$BIN_DIR/SignalApp.build/DerivedSources/resource_bundle_accessor.swift" \
  scripts/export_mascot_gifs.swift -o "$EXPORT_BINARY"
"$EXPORT_BINARY" "$ROOT_DIR/exports/mascot-motion"
