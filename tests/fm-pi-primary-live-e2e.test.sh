#!/usr/bin/env bash
# Opt-in clean-stock Pi watcher lifecycle regression on an isolated tmux socket.
set -u

if [ "${FM_PI_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_LIVE_E2E=1 to run the isolated interactive Pi regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v pi >/dev/null 2>&1 || { echo "not ok - pi is required" >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "not ok - tmux is required" >&2; exit 1; }
AUTH_FILE=${FM_PI_LIVE_AUTH_FILE:-}
[ -n "$AUTH_FILE" ] && [ -f "$AUTH_FILE" ] || { echo "not ok - set FM_PI_LIVE_AUTH_FILE" >&2; exit 1; }

TMUX=$(command -v tmux)
PI_BIN=$(command -v pi)
SOCKET="fm-pi-live-e2e-$$"
SESSION=pi-live-e2e
LAB=$(mktemp -d "$ROOT/.pi-live-e2e.XXXXXX")
PROJECT="$LAB/project"
PI_DIR="$LAB/pi-agent"
ROLE=${FM_PI_LIVE_ROLE:-primary}
MODEL=${FM_PI_LIVE_MODEL:-gpt-5.6-sol}
PROVIDER=${FM_PI_LIVE_PROVIDER:-openai-codex}
THINKING=${FM_PI_LIVE_THINKING:-minimal}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
case "$ROLE" in primary|secondmate) ;; *) fail "FM_PI_LIVE_ROLE must be primary or secondmate" ;; esac

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

capture() { "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -1000 2>/dev/null || true; }
current_lines() { "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true; }

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_status() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    current_lines | grep -Fxq "$expected" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  current_lines >&2
  return 1
}

wait_for_status_absent() {
  local attempts=${1:-120} i=0 pane_dead
  while [ "$i" -lt "$attempts" ]; do
    pane_dead=$("$TMUX" -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_dead}' 2>/dev/null || true)
    [ "$pane_dead" = 1 ] && return 0
    current_lines | grep -Eq '^(offline|watching|handling wake|attention)$' || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

text_count() { capture | grep -Fo "$1" | wc -l | tr -d ' '; }

wait_for_text_count_after() {
  local expected=$1 previous=$2 attempts=${3:-120} i=0 count
  while [ "$i" -lt "$attempts" ]; do
    count=$(text_count "$expected")
    [ "$count" -gt "$previous" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_clean_exit() {
  local i=0 state
  while [ "$i" -lt 120 ]; do
    state=$("$TMUX" -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_dead} #{pane_dead_status}' 2>/dev/null || true)
    [ "$state" = '1 0' ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

send_prompt() {
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

cleanup() {
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

git clone -q "$ROOT" "$PROJECT"
if ! git -C "$ROOT" diff --quiet HEAD -- .pi bin; then
  git -C "$ROOT" diff --binary HEAD -- .pi bin | git -C "$PROJECT" apply
fi
[ "$ROLE" != secondmate ] || : > "$PROJECT/.fm-secondmate-home"
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PI_DIR"
cp "$AUTH_FILE" "$PI_DIR/auth.json"
cat > "$PI_DIR/settings.json" <<JSON
{"defaultProvider":"$PROVIDER","defaultModel":"$MODEL","defaultThinkingLevel":"$THINKING","enableInstallTelemetry":false,"packages":[]}
JSON
PI_CODING_AGENT_DIR="$PI_DIR" PI_OFFLINE=1 pi list 2>&1 | grep -Fq 'No packages installed.' \
  || fail "isolated Pi home is not clean stock"

WATCH="$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
launch="exec env PI_CODING_AGENT_DIR=$(shell_quote "$PI_DIR") FM_HOME=$(shell_quote "$PROJECT") FM_ROOT_OVERRIDE=$(shell_quote "$PROJECT") FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 PI_OFFLINE=1 $(shell_quote "$PI_BIN") --approve --offline --no-session --verbose -e $(shell_quote "$WATCH") 'Reply exactly READY.'"
"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" "$launch"
"$TMUX" -L "$SOCKET" set-window-option -t "$SESSION" remain-on-exit on
wait_for_text READY 180 || fail "Pi did not start with the watcher extension"
wait_for_status offline || fail "fresh watcher status was not offline"
capture | grep -Fq 'Trust project folder?' && fail "--approve produced a trust dialog"

: > "$PROJECT/state/pi-e2e.meta"
send_prompt 'Use fm_watch_arm_pi exactly once. Never use bash to arm. Reply exactly ARMED. After a FIRSTMATE WATCHER WAKE, run bin/fm-wake-drain.sh, do not re-arm, and finish exactly WAKE-HANDLED.'
wait_for_text 'watcher: started Pi extension arm child 1' 180 || fail "native watcher arm did not start"
wait_for_status watching || fail "armed watcher status was not watching"
wake_count=$(text_count WAKE-HANDLED)
printf 'done: pi live e2e watcher fire\n' > "$PROJECT/state/pi-e2e.status"
wait_for_status 'handling wake' 240 || fail "actionable wake status was not handling wake"
wait_for_text_count_after WAKE-HANDLED "$wake_count" 180 || fail "Pi did not handle the watcher wake"

send_prompt 'Use fm_watch_arm_pi exactly once to resume supervision. Reply exactly REARMED.'
wait_for_text 'watcher: started Pi extension arm child 2' 180 || fail "native watcher did not re-arm"
wait_for_status watching 180 || fail "re-armed watcher status was not watching"
pid_file=$(find "$PROJECT/state" -maxdepth 3 -type f -name pid | head -1)
watcher_pid=$(sed -n '1p' "$pid_file")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "watcher arm process was not live"

before_failure=$(capture | grep -Fc 'FIRSTMATE WATCHER WAKE: watcher: FAILED' || true)
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l /reload
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_status_absent 60 || fail "reload did not clear old status"
wait_for_text 'Reloaded keybindings' 120 || fail "Pi reload did not complete"
wait_for_status offline 120 || fail "reloaded watcher status was not offline"
wait_pid_dead "$watcher_pid" || fail "old watcher survived reload"
wait_pid_dead "$arm_pid" || fail "old arm survived reload"
after_failure=$(capture | grep -Fc 'FIRSTMATE WATCHER WAKE: watcher: FAILED' || true)
[ "$after_failure" -eq "$before_failure" ] || fail "reload emitted a false failure wake"

send_prompt 'Use fm_watch_arm_pi exactly once after reload. Reply exactly RELOAD-REARMED.'
wait_for_text 'watcher: started Pi extension arm child 3' 180 || fail "watcher did not arm after reload"
wait_for_status watching 180 || fail "post-reload watcher status was not watching"
new_pid_file=$(find "$PROJECT/state" -maxdepth 3 -type f -name pid | head -1)
new_watcher_pid=$(sed -n '1p' "$new_pid_file")
new_arm_pid=$(ps -p "$new_watcher_pid" -o ppid= | tr -d ' ')

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l /quit
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_status_absent 60 || fail "quit did not clear watcher status"
wait_for_clean_exit || fail "Pi did not exit cleanly"
wait_pid_dead "$new_watcher_pid" || fail "watcher survived clean Pi exit"
wait_pid_dead "$new_arm_pid" || fail "arm survived clean Pi exit"
orphan=$(pgrep -af "$LAB" 2>/dev/null | grep -E 'pi-coding-agent|fm-watch' || true)
[ -z "$orphan" ] || fail "owned live lab left a process: $orphan"

printf 'ok - Pi %s watcher lifecycle passed for %s with clean reload and exit\n' "$(pi --version)" "$ROLE"
