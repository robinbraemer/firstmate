#!/usr/bin/env bash
# Opt-in clean-stock Pi watcher lifecycle regression on an isolated tmux socket.
set -u

scan_lab_processes() {
  local lab=$1 snapshot
  snapshot=$(ps -axo pid=,ppid=,stat=,command= 2>/dev/null) || return 1
  printf '%s\n' "$snapshot" \
    | awk -v lab="$lab" 'index($0, lab) && $3 !~ /^Z/' \
    | grep -E '(^|[ /])(pi|pi-coding-agent|fm-watch(-arm)?\.sh)([ /]|$)' \
    || true
}

wait_for_scanned_processes_gone() {
  local lab=$1 attempts=${2:-50} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -z "$(scan_lab_processes "$lab")" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

signal_scanned_processes() {
  local lab=$1 signal=$2 pid _
  while read -r pid _; do
    [ -n "$pid" ] && kill -"$signal" "$pid" 2>/dev/null || true
  done <<EOF
$(scan_lab_processes "$lab")
EOF
}

terminate_scanned_processes() {
  local lab=$1 attempts=${2:-50}
  [ -z "$(scan_lab_processes "$lab")" ] && return 0
  signal_scanned_processes "$lab" TERM
  wait_for_scanned_processes_gone "$lab" "$attempts" && return 0
  signal_scanned_processes "$lab" KILL
  wait_for_scanned_processes_gone "$lab" "$attempts"
}

if [ "${1:-}" = --process-scan-self-test ]; then
  scan_lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-live-scan.XXXXXX")
  bash -c 'trap "exit 0" TERM; while :; do sleep 1; done' "$scan_lab/fm-watch-arm.sh" &
  scan_pid_one=$!
  bash -c 'trap "" TERM; while :; do sleep 1; done' "$scan_lab/fm-watch.sh" &
  scan_pid_two=$!
  sleep 0.1
  scan_out=$(scan_lab_processes "$scan_lab")
  if [ "$(printf '%s\n' "$scan_out" | awk 'NF { count += 1 } END { print count + 0 }')" -ne 2 ] \
    || ! printf '%s\n' "$scan_out" | awk -v one="$scan_pid_one" -v two="$scan_pid_two" '$1 == one { first = 1 } $1 == two { second = 1 } END { exit !(first && second) }'; then
    kill -KILL "$scan_pid_one" "$scan_pid_two" 2>/dev/null || true
    wait "$scan_pid_one" "$scan_pid_two" 2>/dev/null || true
    rm -rf "$scan_lab"
    printf 'not ok - Pi live process scanner returned: %s\n' "$scan_out" >&2
    exit 1
  fi
  terminate_scanned_processes "$scan_lab" 3 || {
    printf 'not ok - Pi live cleanup left processes: %s\n' "$(scan_lab_processes "$scan_lab")" >&2
    exit 1
  }
  wait "$scan_pid_one" "$scan_pid_two" 2>/dev/null || true
  rm -rf "$scan_lab"
  echo "ok - Pi live cleanup isolates and terminates lab-owned processes"
  exit 0
fi

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
EVIDENCE_ROOT=${FM_PI_LIVE_EVIDENCE_ROOT:-${TMPDIR:-/tmp}/no-mistakes-evidence}
mkdir -p "$EVIDENCE_ROOT"
LAB=$(mktemp -d "$EVIDENCE_ROOT/fm-pi-live-e2e.XXXXXX")
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

wait_for_text_line() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    current_lines | grep -Fxq "$expected" && return 0
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

lab_processes() {
  scan_lab_processes "$LAB"
}

terminate_lab_processes() {
  terminate_scanned_processes "$LAB"
}

cleanup() {
  local status=$? survivors
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  if terminate_lab_processes; then
    rm -rf "$LAB"
  else
    survivors=$(lab_processes)
    printf 'not ok - lab-owned processes survived cleanup; evidence retained at %s\n%s\n' "$LAB" "$survivors" >&2
    status=1
  fi
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT

git clone -q "$ROOT" "$PROJECT"
if ! git -C "$ROOT" diff --quiet HEAD -- .pi bin; then
  git -C "$ROOT" diff --binary HEAD -- .pi bin | git -C "$PROJECT" apply
fi
[ "$ROLE" != secondmate ] || : > "$PROJECT/.fm-secondmate-home"
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PI_DIR"
chmod 700 "$LAB" "$PI_DIR"
cp "$AUTH_FILE" "$PI_DIR/auth.json"
chmod 600 "$PI_DIR/auth.json"
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
wait_for_status watching 180 || fail "watcher did not auto-arm at session start"
capture | grep -Fq 'Trust project folder?' && fail "--approve produced a trust dialog"

: > "$PROJECT/state/pi-e2e.meta"
pid_file=$(find "$PROJECT/state" -maxdepth 3 -type f -name pid | head -1)
watcher_pid=$(sed -n '1p' "$pid_file")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "watcher arm process was not live"
send_prompt 'After a FIRSTMATE WATCHER WAKE, run bin/fm-wake-drain.sh, do not re-arm, and finish exactly WAKE-HANDLED.'
wake_count=$(text_count WAKE-HANDLED)
printf 'done: pi live e2e watcher fire\n' > "$PROJECT/state/pi-e2e.status"
wait_for_text_count_after WAKE-HANDLED "$wake_count" 180 || fail "Pi did not handle the watcher wake"
wait_pid_dead "$watcher_pid" || fail "completed watcher survived automatic re-arm"
wait_pid_dead "$arm_pid" || fail "completed arm survived automatic re-arm"
for _ in $(seq 1 120); do
  new_pid_file=$(find "$PROJECT/state" -maxdepth 3 -type f -name pid | head -1)
  new_watcher_pid=$(sed -n '1p' "$new_pid_file" 2>/dev/null || true)
  [ -n "$new_watcher_pid" ] && [ "$new_watcher_pid" != "$watcher_pid" ] && break
  sleep 0.25
done
[ -n "${new_watcher_pid:-}" ] && [ "$new_watcher_pid" != "$watcher_pid" ] || fail "actionable wake did not auto-arm a replacement watcher"
new_arm_pid=$(ps -p "$new_watcher_pid" -o ppid= | tr -d ' ')
[ -n "$new_arm_pid" ] || fail "replacement watcher arm process was not live"
wait_for_status watching 180 || fail "automatic replacement watcher status was not watching"
watcher_pid=$new_watcher_pid
arm_pid=$new_arm_pid

before_failure=$(capture | grep -Fc 'FIRSTMATE WATCHER WAKE: watcher: FAILED' || true)
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l /reload
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_status_absent 60 || fail "reload did not clear old status"
wait_for_text 'Reloaded keybindings' 120 || fail "Pi reload did not complete"
wait_for_status watching 120 || fail "reloaded watcher did not auto-arm"
wait_pid_dead "$watcher_pid" || fail "old watcher survived reload"
wait_pid_dead "$arm_pid" || fail "old arm survived reload"
after_failure=$(capture | grep -Fc 'FIRSTMATE WATCHER WAKE: watcher: FAILED' || true)
[ "$after_failure" -eq "$before_failure" ] || fail "reload emitted a false failure wake"

new_pid_file=$(find "$PROJECT/state" -maxdepth 3 -type f -name pid | head -1)
new_watcher_pid=$(sed -n '1p' "$new_pid_file")
new_arm_pid=$(ps -p "$new_watcher_pid" -o ppid= | tr -d ' ')

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l /quit
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_status_absent 60 || fail "quit did not clear watcher status"
wait_for_clean_exit || fail "Pi did not exit cleanly"
wait_pid_dead "$new_watcher_pid" || fail "watcher survived clean Pi exit"
wait_pid_dead "$new_arm_pid" || fail "arm survived clean Pi exit"
orphan=$(lab_processes)
[ -z "$orphan" ] || fail "owned live lab left a process: $orphan"

printf 'ok - Pi %s watcher lifecycle passed for %s with clean reload and exit\n' "$(pi --version)" "$ROLE"
