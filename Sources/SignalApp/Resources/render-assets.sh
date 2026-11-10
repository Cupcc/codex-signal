#!/bin/bash
set -euo pipefail
ASSET_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
for pose in working attention question idle error ready; do
  /usr/bin/sips -s format png "$ASSET_ROOT/design/assets/toy-$pose.svg" --out "$ASSET_ROOT/Sources/SignalApp/Resources/toy-$pose.png" >/dev/null
  /usr/bin/sips -s format png "$ASSET_ROOT/design/assets/toy-mini-$pose.svg" --out "$ASSET_ROOT/Sources/SignalApp/Resources/toy-mini-$pose.png" >/dev/null
done
python3 "$ASSET_ROOT/scripts/render_mascot_layers.py"
