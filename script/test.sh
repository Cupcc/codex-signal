#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
FILTER=""
case "${1:-}" in
  "") test "$#" -eq 0 || exit 2 ;;
  --filter)
    if test "$#" -ne 2 || test -z "$2"; then
      echo "usage: $0 [--filter REGEX]" >&2
      exit 2
    fi
    FILTER="$2"
    ;;
  --help|-h)
    echo "usage: $0 [--filter REGEX]"
    echo "No arguments: all Swift and Python tests. --filter: matching Swift tests only."
    exit 0
    ;;
  *) echo "usage: $0 [--filter REGEX]" >&2; exit 2 ;;
esac

DEVELOPER_DIR_PATH="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
# Native window tests share AppKit's main thread with the timer-based model tests.
SWIFT_TEST_ARGS=(--no-parallel --disable-xctest --enable-swift-testing)
if test -d "$FRAMEWORKS/Testing.framework"; then
  SWIFT_TEST_ARGS+=(
    -Xswiftc -F -Xswiftc "$FRAMEWORKS"
    -Xlinker -F -Xlinker "$FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$DEVELOPER_DIR_PATH/Library/Developer/usr/lib")
fi
if test -n "$FILTER"; then
  SWIFT_TEST_ARGS+=(--filter "$FILTER")
  # Swift Testing's list command includes all tests even when --filter is set.
  MATCHES="$(swift test list "${SWIFT_TEST_ARGS[@]}" | python3 -c '
import re, sys
pattern = re.compile(sys.argv[1])
print("".join(line for line in sys.stdin if pattern.search(line)), end="")
' "$FILTER")"
  if test -z "$MATCHES"; then
    echo "No Swift tests match: $FILTER" >&2
    exit 2
  fi
  printf 'Selected Swift tests:\n%s\n' "$MATCHES"
fi
swift test "${SWIFT_TEST_ARGS[@]}"
if test -n "$FILTER"; then exit 0; fi

python3 scripts/test_bridge.py

python3 scripts/test_correlation.py

python3 scripts/test_update_installer.py

python3 scripts/test_configure_hooks.py
