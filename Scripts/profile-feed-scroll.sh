#!/usr/bin/env bash
# Build bilibili, auto-scroll the feed, record Instruments trace, and summarize hotspots.
#
# Usage:
#   ./Scripts/profile-feed-scroll.sh                 # profile home feed (default)
#   ./Scripts/profile-feed-scroll.sh scrollTest      # profile scroll test tab
#   ./Scripts/profile-feed-scroll.sh compare         # home then scroll-test baseline
#   ./Scripts/profile-feed-scroll.sh home --release --rounds 80 --time-limit 60s
#
# Requires:
#   - Xcode (xctrace)
#   - Accessibility permission for Terminal (scroll simulator)
#
# Output: perf-traces/<timestamp>-<section>/

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
SECTION="home"
ROUNDS=60
WARMUP=3
TIME_LIMIT="45s"
BUILD_CONFIG="Debug"
OPEN_TRACE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    home|scrollTest|compare)
      SECTION="$1"
      shift
      ;;
    --rounds) ROUNDS="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --time-limit) TIME_LIMIT="$2"; shift 2 ;;
    --release) BUILD_CONFIG="Release"; shift ;;
    --no-open) OPEN_TRACE=0; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

resolve_app_path() {
  local app_path
  app_path="$("$XCODEBUILD" -scheme bilibili -destination 'platform=macOS' -configuration "$BUILD_CONFIG" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/TARGET_BUILD_DIR/ { dir=$2 } /FULL_PRODUCT_NAME/ { name=$2 } END { print dir "/" name }')"
  if [[ ! -d "$app_path" ]]; then
    app_path="$(find "$HOME/Library/Developer/Xcode/DerivedData/bilibili-"*/Build/Products -name 'bilibili.app' -path "*/${BUILD_CONFIG}/*" 2>/dev/null | head -1)"
  fi
  if [[ ! -d "$app_path" ]]; then
    echo "error: bilibili.app not found after build" >&2
    exit 1
  fi
  echo "$app_path"
}

launch_args_for_section() {
  local section="$1"
  case "$section" in
    home)
      echo "-ApplePersistenceIgnoreState YES -BiliPerfHome -BiliPerfNoPrefetch"
      ;;
    scrollTest)
      echo "-ApplePersistenceIgnoreState YES -BiliPerfScrollTest"
      ;;
    *)
      echo "error: unknown section $section" >&2
      exit 1
      ;;
  esac
}

profile_section() {
  local section="$1"
  local stamp out_dir trace_path app_path
  stamp="$(date +%Y%m%d-%H%M%S)"
  out_dir="$ROOT/perf-traces/${stamp}-${section}"
  mkdir -p "$out_dir"
  trace_path="$out_dir/recording.trace"

  echo "" >&2
  echo "========================================" >&2
  echo " Profiling section: $section" >&2
  echo " Output: $out_dir" >&2
  echo "========================================" >&2

  echo "==> Stopping previous bilibili instances…" >&2
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1
  pkill -x bilibili >/dev/null 2>&1 || true
  sleep 0.5

  echo "==> Launching app ($section)…" >&2
  # shellcheck disable=SC2046
  open -a "$APP_PATH" --args $(launch_args_for_section "$section")
  sleep 2

  echo "==> Waiting for process…" >&2
  for _ in $(seq 1 40); do
    if pgrep -x bilibili >/dev/null; then
      break
    fi
    sleep 0.2
  done
  if ! pgrep -x bilibili >/dev/null; then
    echo "error: bilibili process did not start" >&2
    exit 1
  fi

  echo "==> Recording ($TIME_LIMIT, Time Profiler + Hitches)…" >&2
  "$XCTRACE" record \
    --template 'Time Profiler' \
    --instrument 'Hitches' \
    --attach bilibili \
    --time-limit "$TIME_LIMIT" \
    --output "$trace_path" \
    --no-prompt \
    >"$out_dir/xctrace.log" 2>&1 &
  local trace_pid=$!

  sleep 4

  echo "==> Auto-scrolling ($ROUNDS rounds)…" >&2
  if swift "$ROOT/Scripts/scroll-simulator.swift" \
    --bundle "$BUNDLE_ID" \
    --rounds "$ROUNDS" \
    --warmup "$WARMUP" \
    >"$out_dir/scroll.log" 2>&1; then
    echo "    Scroll simulation finished." >&2
  else
    echo "    Scroll simulation failed — check $out_dir/scroll.log (Accessibility permission?)" >&2
  fi

  wait "$trace_pid" || true

  if [[ ! -d "$trace_path" ]]; then
    echo "error: trace not created. See $out_dir/xctrace.log" >&2
    cat "$out_dir/xctrace.log" >&2
    exit 1
  fi

  echo "==> Analyzing trace…" >&2
        python3 "$ROOT/Scripts/analyze-trace.py" "$trace_path" --out-dir "$out_dir" --section "$section" >"$out_dir/analysis.log"
        cat "$out_dir/analysis.log" >&2

  if [[ "$OPEN_TRACE" -eq 1 ]]; then
    open "$trace_path" || true
  fi

  echo "$out_dir"
}

echo "==> Building ($BUILD_CONFIG)…"
STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_DIR="$ROOT/perf-traces/${STAMP}-build"
mkdir -p "$BUILD_DIR"
"$XCODEBUILD" \
  -scheme bilibili \
  -destination 'platform=macOS' \
  -configuration "$BUILD_CONFIG" \
  build >"$BUILD_DIR/build.log" 2>&1
APP_PATH="$(resolve_app_path)"
echo "    App: $APP_PATH"

if [[ "$SECTION" == "compare" ]]; then
  HOME_OUT="$(profile_section home)"
  SCROLL_OUT="$(profile_section scrollTest)"
  COMPARE_DIR="$ROOT/perf-traces/${STAMP}-compare"
  mkdir -p "$COMPARE_DIR"
  python3 "$ROOT/Scripts/analyze-trace.py" --compare "$HOME_OUT/recording.trace" "$SCROLL_OUT/recording.trace" \
    --out-dir "$COMPARE_DIR" >"$COMPARE_DIR/comparison.log"
  cat "$COMPARE_DIR/comparison.log"
  echo ""
  echo "Compare report: $ROOT/perf-traces/${STAMP}-compare/comparison.txt"
else
  OUT_DIR="$(profile_section "$SECTION")"
  echo ""
  echo "Done."
  echo "  Trace dir: $OUT_DIR"
  echo "  Hotspots:  $OUT_DIR/hotspots.txt"
fi
