#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER_DIR_PATH="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
if test -d "$FRAMEWORKS/Testing.framework"; then
  swift test --disable-xctest --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"
else
  swift test --disable-xctest --enable-swift-testing
fi
python3 scripts/test_bridge.py

python3 scripts/test_correlation.py

python3 scripts/test_update_installer.py
