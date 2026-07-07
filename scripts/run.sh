#!/usr/bin/env bash
# Run the whole Claude Traffic Light program end to end, in one command:
#   1. build the release binaries
#   2. wire up the Claude Code hooks (reporter install)  [idempotent]
#   3. launch the overlay in the foreground and wait
#
# On quit (right-click the light -> Quit, or Ctrl-C here), the overlay stops and the hooks
# are LEFT INSTALLED. They're global (~/.claude/settings.json) and harmless — async,
# fire-and-forget, idempotent — and removing them would stop status reporting for your other
# Claude windows too, freezing the Light on a stale colour. Run `reporter uninstall` when you
# actually want them gone.
#
# Pass --teardown (or set CTL_TEARDOWN=1) for a throwaway run that also uninstalls the hooks
# and clears state on quit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPORTER=".build/release/reporter"
OVERLAY=".build/release/TrafficLight"
HOME_DIR="${CLAUDE_TRAFFIC_LIGHT_HOME:-$HOME/.claude-traffic-light}"

teardown="${CTL_TEARDOWN:-0}"
for a in "$@"; do [ "$a" = "--teardown" ] && teardown=1; done

installed=0

# Runs on normal quit, Ctrl-C, or error. Idempotent — safe if we never got to install.
cleanup() {
  trap - EXIT INT TERM  # don't re-enter
  echo
  if [ "$teardown" = 1 ]; then
    echo "==> tearing down (--teardown): removing hooks and clearing state"
    [ "$installed" = 1 ] && [ -x "$REPORTER" ] && "$REPORTER" uninstall || true
    rm -rf "$HOME_DIR"
    echo "==> done — hooks removed and state cleared"
  else
    echo "==> overlay stopped. Hooks left installed so your other windows keep reporting."
    echo "    (remove them with: $REPORTER uninstall)"
  fi
}
trap cleanup EXIT INT TERM

echo "==> building release binaries"
swift build -c release

echo "==> installing hooks (idempotent)"
"$REPORTER" install
installed=1

echo "==> launching overlay"
echo "    Right-click the light -> Quit, or press Ctrl-C here, to stop."
"$OVERLAY"
