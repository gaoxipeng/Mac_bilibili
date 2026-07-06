#!/usr/bin/env bash
# Build bilibili, record Time Profiler + Core Animation while auto-scrolling the home feed.
#
# Usage:
#   ./Scripts/perf-profile-home.sh
#   ./Scripts/perf-profile-home.sh --rounds 80 --time-limit 60s
#
# Requires: Xcode (xctrace), Accessibility permission for Terminal.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
elif [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

XCTRACE="${DEVELOPER_DIR:-}/usr/bin/xctrace"
XCODEBUILD="${DEVELOPER_DIR:-}/usr/bin/xcodebuild"
if [[ ! -x "$XCTRACE" ]]; then
  XCTRACE="$(command -v xctrace || true)"
fi
if [[ ! -x "$XCODEBUILD" ]]; then
  XCODEBUILD="$(command -v xcodebuild || true)"
fi

if [[ ! -x "$XCTRACE" || ! -x "$XCODEBUILD" ]]; then
  echo "error: Xcode CLI tools not found. Install Xcode and retry." >&2
  exit 1
fi

BUNDLE_ID="gaoxipeng.bilibili"
ROUNDS=60
WARMUP=3
TIME_LIMIT="50s"
BUILD_CONFIG="Debug"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rounds) ROUNDS="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --time-limit) TIME_LIMIT="$2"; shift 2 ;;
    --release) BUILD_CONFIG="Release"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ROOT/perf-traces/${STAMP}-home"
mkdir -p "$OUT_DIR"

echo "==> Building ($BUILD_CONFIG)…"
"$XCODEBUILD" \
  -scheme bilibili \
  -destination 'platform=macOS' \
  -configuration "$BUILD_CONFIG" \
  build >"$OUT_DIR/build.log" 2>&1

APP_PATH="$("$XCODEBUILD" -scheme bilibili -destination 'platform=macOS' -configuration "$BUILD_CONFIG" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/TARGET_BUILD_DIR/ { dir=$2 } /FULL_PRODUCT_NAME/ { name=$2 } END { print dir "/" name }')"
if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData/bilibili-"*/Build/Products -name 'bilibili.app' -path "*/${BUILD_CONFIG}/*" 2>/dev/null | head -1)"
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: bilibili.app not found after build" >&2
  exit 1
fi
echo "    App: $APP_PATH"

echo "==> Stopping previous bilibili instances…"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 1
pkill -x bilibili >/dev/null 2>&1 || true
sleep 0.5

echo "==> Launching app…"
open -a "$APP_PATH" --args -ApplePersistenceIgnoreState YES
sleep 2

echo "==> Waiting for process…"
ATTACH_NAME="bilibili"
for _ in $(seq 1 30); do
  if pgrep -x bilibili >/dev/null; then
    break
  fi
  sleep 0.2
done
if ! pgrep -x bilibili >/dev/null; then
  echo "error: bilibili process did not start" >&2
  exit 1
fi

TRACE_PATH="$OUT_DIR/recording.trace"
echo "==> Recording ($TIME_LIMIT, Time Profiler + Core Animation)…"

  "$XCTRACE" record \
    --template 'Time Profiler' \
    --instrument 'Hitches' \
  --attach "$ATTACH_NAME" \
  --time-limit "$TIME_LIMIT" \
  --output "$TRACE_PATH" \
  --no-prompt \
  >"$OUT_DIR/xctrace.log" 2>&1 &
TRACE_PID=$!

# Wait for Instruments to attach before scrolling.
sleep 4

echo "==> Auto-scrolling feed…"
if swift "$ROOT/Scripts/scroll-simulator.swift" \
  --bundle "$BUNDLE_ID" \
  --rounds "$ROUNDS" \
  --warmup "$WARMUP" \
  >"$OUT_DIR/scroll.log" 2>&1; then
  echo "    Scroll simulation finished."
else
  echo "    Scroll simulation failed — check $OUT_DIR/scroll.log (Accessibility permission?)" >&2
fi

wait "$TRACE_PID" || true

if [[ ! -d "$TRACE_PATH" ]]; then
  echo "error: trace not created. See $OUT_DIR/xctrace.log" >&2
  cat "$OUT_DIR/xctrace.log" >&2
  exit 1
fi

echo "==> Analyzing trace…"
python3 "$ROOT/Scripts/analyze-trace.py" "$TRACE_PATH" --out-dir "$OUT_DIR" | tee "$OUT_DIR/analysis.log"

echo ""
echo "Done."
echo "  Trace:     $TRACE_PATH"
echo "  Hotspots:  $OUT_DIR/hotspots.txt"
echo "  Open trace: open \"$TRACE_PATH\""
