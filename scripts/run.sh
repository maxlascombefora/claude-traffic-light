#!/usr/bin/env bash
# Run the whole Claude Traffic Light program end to end, in one command:
#   1. build the release binaries
#   2. wire up the Claude Code hooks (reporter install)
#   3. launch the overlay in the foreground and wait
#
# When you quit the overlay (right-click the light -> Quit, or press Ctrl-C in this
# terminal), the hooks are removed and transient session state is cleared automatically,
# leaving your machine as it was before the run.
#
# Note: the hooks live in ~/.claude/settings.json and are global, so installing/removing
# them affects every Claude Code session, not just this one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPORTER=".build/release/reporter"
OVERLAY=".build/release/TrafficLight"
HOME_DIR="${CLAUDE_TRAFFIC_LIGHT_HOME:-$HOME/.claude-traffic-light}"

installed=0

# Runs on normal quit, Ctrl-C, or error. Idempotent — safe if we never got to install.
cleanup() {
  trap - EXIT  # don't re-enter
  echo
  echo "==> cleaning up"
  if [ "$installed" = 1 ] && [ -x "$REPORTER" ]; then
    "$REPORTER" uninstall || true
  fi
  rm -rf "$HOME_DIR"
  echo "==> done — hooks removed and state cleared"
}
trap cleanup EXIT INT TERM

echo "==> building release binaries"
swift build -c release

echo "==> installing hooks"
"$REPORTER" install
installed=1

echo "==> launching overlay"
echo "    Right-click the light -> Quit, or press Ctrl-C here, to stop and clean up."
"$OVERLAY"
