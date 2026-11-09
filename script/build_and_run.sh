#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
case "$MODE" in
  run|--build|--verify|--demo|--debug|--logs|--telemetry) ;;
  *) echo "usage: $0 [run|--build|--verify|--demo|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
if test "$MODE" != --build; then pkill -x CodexSignal 2>/dev/null || true; fi
"$ROOT_DIR/script/build_app.sh"
APP="$ROOT_DIR/dist/CodexSignal.app"
if test "$MODE" = --build; then exit 0; fi
case "$MODE" in
  --demo) open -n "$APP" --args --demo ;;
  --debug) lldb -- "$APP/Contents/MacOS/CodexSignal" ;;
  --logs|--telemetry)
    open -n "$APP"
    /usr/bin/log stream --info --style compact --predicate 'process == "CodexSignal"'
    ;;
  --verify)
    open -n "$APP"
    sleep 1
    pgrep -x CodexSignal >/dev/null
    echo "CodexSignal process is running"
    ;;
  run) open -n "$APP" ;;
esac
