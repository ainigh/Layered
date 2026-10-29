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
# Opened the way a person opens it (Launch Services, as the Finder and install.sh do), not run
# from the shell: an app started either way can behave differently.
open -n --stdout build/smoke.log --stderr build/smoke.log build/Mindmap.app
sleep 15
pid="$(pgrep -nf "$PWD/$BIN" || true)"
if [[ -z "$pid" ]]; then
  echo "❌ the app quit within 15 seconds of opening. Its output:"
  cat build/smoke.log
  exit 1
fi

if ! kill -0 "$pid" 2>/dev/null; then
  echo "❌ the app quit within 15 seconds of opening. Its output:"
  cat build/smoke.log
  exit 1
fi
echo "✅ still running after 15 seconds"

sample "$pid" 3 -file build/sample.txt >/dev/null 2>&1 || true
echo "--- the main thread over 3 seconds (idle is mostly mach_msg in the run loop) ---"
sed -n '/com.apple.main-thread/,/^ *[0-9][0-9]* Thread_/p' build/sample.txt | head -200
# Click the menu bar icon the way a person would, and list what its menu holds (needs the runner's
# accessibility permission; without it this only says so).
echo "--- clicking the menu bar icon ---"
perl -e 'alarm 30; exec @ARGV' osascript <<'OSA' 2>&1 | tee build/click.log || true
tell application "System Events"
  tell process "Mindmap"
    log ("windows: " & (count of windows))
    set extras to menu bar 2
    log ("menu bar items: " & (count of menu bar items of extras))
    click menu bar item 1 of extras
    delay 2
    set m to menu 1 of menu bar item 1 of extras
    log ("menu items: " & (count of menu items of m))
    repeat with i in (menu items of m)
      try
        log ("  " & (title of i as text))
      on error
        log "  (unnamed item)"
      end try
    end repeat
    click menu item "Open Mindmap" of m
    delay 3
    log ("windows after Open Mindmap: " & (count of windows))
  end tell
end tell
OSA

# With the window open: is the app still answering, and does the menu still open?
sleep 5
echo "--- with the window open: CPU and the main thread ---"
ps -o %cpu=,stat= -p "$pid" || true
sample "$pid" 3 -file build/sample-window.txt >/dev/null 2>&1 || true
sed -n '/com.apple.main-thread/,/^ *[0-9][0-9]* Thread_/p' build/sample-window.txt | head -120
perl -e 'alarm 30; exec @ARGV' osascript <<'OSA' 2>&1 | tee -a build/click.log || true
tell application "System Events"
  tell process "Mindmap"
    click menu bar item 1 of menu bar 2
    delay 2
    log ("menu items with the window open: " & (count of menu items of menu 1 of menu bar item 1 of menu bar 2))
    key code 53
  end tell
end tell
OSA

echo "--- the app's output ---"
head -100 build/smoke.log
kill "$pid" 2>/dev/null || true
if grep -q "windows after Open Mindmap: 1" build/click.log && ! grep -q "menu items with the window open: [1-9]" build/click.log; then
  echo "❌ with the window open, the menu bar menu no longer opens"
  exit 1
fi
if grep -q "windows after Open Mindmap: 0" build/click.log; then
  echo "❌ Open Mindmap in the menu bar menu opened no window"
  exit 1
fi
