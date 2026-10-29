#!/bin/bash
# Opens the built app, waits, and checks it is still running; then prints what its main thread is
# doing. A main thread that is busy rather than waiting for events is a menu bar icon that ignores
# clicks, so the sample says where it's stuck. GitHub Actions runs it after every build.
#
#   scripts/smoke-test.sh            (after scripts/build-app.sh)
set -uo pipefail
cd "$(dirname "$0")/../App"

BIN=build/Mindmap.app/Contents/MacOS/Mindmap
[[ -x "$BIN" ]] || { echo "no $BIN: run scripts/build-app.sh first" >&2; exit 1; }
"$BIN" > build/smoke.log 2>&1 &
pid=$!
sleep 15

if ! kill -0 "$pid" 2>/dev/null; then
  echo "❌ the app quit within 15 seconds of opening. Its output:"
  cat build/smoke.log
  exit 1
fi
echo "✅ still running after 15 seconds"

sample "$pid" 3 -file build/sample.txt >/dev/null 2>&1 || true
echo "--- the main thread over 3 seconds (idle is mostly mach_msg in the run loop) ---"
sed -n '/com.apple.main-thread/,/^ *[0-9][0-9]* Thread_/p' build/sample.txt | head -200
echo "--- the app's output ---"
head -100 build/smoke.log
kill "$pid" 2>/dev/null || true
