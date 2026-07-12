#!/usr/bin/env bash
# Opt-in interactive Pi primary/secondmate regression on an isolated tmux socket.
set -u

if [ "${FM_PI_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_LIVE_E2E=1 to run the isolated interactive Pi regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v pi >/dev/null 2>&1 || { echo "not ok - pi is required for the live Pi regression" >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "not ok - tmux is required for the live Pi regression" >&2; exit 1; }
AUTH_FILE=${FM_PI_LIVE_AUTH_FILE:-}
[ -n "$AUTH_FILE" ] && [ -f "$AUTH_FILE" ] || { echo "not ok - set FM_PI_LIVE_AUTH_FILE to the auth.json imported into the isolated Pi home" >&2; exit 1; }

TMUX=$(command -v tmux)
PI_BIN=$(command -v pi)
LAUNCH_HELPER="$ROOT/tests/fm-pi-detached-launch-helper.sh"
SOCKET="fm-pi-live-e2e-$$"
SESSION=pi-live-e2e
LAB=$(mktemp -d "$ROOT/.pi-live-e2e.XXXXXX")
LAB_SENTINEL="$LAB/.fm-pi-live-e2e-owned"
PROJECT="$LAB/project with spaces"
PI_DIR="$LAB/pi agent"
PI_VERSION=$(pi --version)
PROVIDER=${FM_PI_LIVE_PROVIDER:-openai-codex}
MODEL=${FM_PI_LIVE_MODEL:-gpt-5.6-sol}
THINKING=${FM_PI_LIVE_THINKING:-minimal}
ROLE=${FM_PI_LIVE_ROLE:-primary}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

case "$ROLE" in
  primary|secondmate) ;;
  *) fail "FM_PI_LIVE_ROLE must be primary or secondmate" ;;
esac

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

build_pi_launch_command() {
  local watch=$1 probe=$2 prompt=$3
  printf '%s %s %s %s %s %s %s' \
    "$(shell_quote "$LAUNCH_HELPER")" \
    "$(shell_quote "$PI_BIN")" \
    "$(shell_quote "$PI_DIR")" \
    "$(shell_quote "$PROJECT")" \
    "$(shell_quote "$watch")" \
    "$(shell_quote "$probe")" \
    "$(shell_quote "$prompt")"
}

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -1200 2>/dev/null || true
}

capture_current() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true
}

current_status_lines() {
  capture_current | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

wait_for_status() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    current_status_lines | grep -Fxq "$expected" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  capture_current >&2
  return 1
}

wait_for_status_absent() {
  local attempts=${1:-120} i=0 pane_dead
  while [ "$i" -lt "$attempts" ]; do
    pane_dead=$("$TMUX" -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_dead}' 2>/dev/null || true)
    [ "$pane_dead" = 1 ] && return 0
    if ! current_status_lines | grep -Eq '^(offline|watching|handling wake|attention)$'; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  capture_current >&2
  return 1
}

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fq "$expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

text_count() {
  local expected=$1
  capture | grep -Fo "$expected" | wc -l | tr -d ' '
}

wait_for_text_count_after() {
  local expected=$1 previous=$2 attempts=${3:-120} i=0 count
  while [ "$i" -lt "$attempts" ]; do
    count=$(text_count "$expected")
    [ "$count" -gt "$previous" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_file() {
  local path=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -s "$path" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

wait_for_settled_composer() {
  local attempts=${1:-120} i=0 tail previous='' stable=0
  while [ "$i" -lt "$attempts" ]; do
    tail=$(capture | tail -16)
    if [ "$tail" = "$previous" ]; then stable=$((stable + 1)); else stable=0; previous=$tail; fi
    if [ "$stable" -ge 4 ] \
      && printf '%s\n' "$tail" | grep -Fq "$MODEL" \
      && ! printf '%s\n' "$tail" | grep -Eiq 'esc to cancel|waiting for tool|thinking'; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  capture >&2
  return 1
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local pid_file watcher_pid arm_pid
  pid_file=$(find "$PROJECT/state" -maxdepth 3 -type f -name pid 2>/dev/null | head -1 || true)
  watcher_pid=
  arm_pid=
  if [ -n "$pid_file" ]; then
    watcher_pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
    arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  fi
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  if [ "${FM_PI_LIVE_KEEP_LAB:-0}" != 1 ] && [ -f "$LAB_SENTINEL" ]; then
    rm -rf "$LAB"
  fi
}
trap cleanup EXIT

send_prompt() {
  local prompt=$1
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$prompt"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 80 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_pi_exit_zero() {
  local i=0 pane_state
  while [ "$i" -lt 120 ]; do
    pane_state=$("$TMUX" -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_dead} #{pane_dead_status}' 2>/dev/null || true)
    [ "$pane_state" = '1 0' ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  printf 'pane exit state: %s\n' "$pane_state" >&2
  return 1
}

: > "$LAB_SENTINEL"
git clone -q "$ROOT" "$PROJECT"
# Before the candidate commit exists, apply its current product diff to the
# clone. After commit this is an empty patch and the clone already has it.
if ! git -C "$ROOT" diff --quiet HEAD -- .pi bin; then
  git -C "$ROOT" diff --binary HEAD -- .pi bin | git -C "$PROJECT" apply
fi
[ "$ROLE" != secondmate ] || : > "$PROJECT/.fm-secondmate-home"
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PI_DIR"
cp "$AUTH_FILE" "$PI_DIR/auth.json"
cat > "$PI_DIR/settings.json" <<JSON
{
  "defaultProvider": "$PROVIDER",
  "defaultModel": "$MODEL",
  "defaultThinkingLevel": "$THINKING",
  "enableInstallTelemetry": false,
  "packages": []
}
JSON

package_inventory=$(PI_CODING_AGENT_DIR="$PI_DIR" PI_OFFLINE=1 pi list 2>&1)
printf '%s\n' "$package_inventory" | grep -Fq 'No packages installed.' || fail "isolated Pi home unexpectedly has packages: $package_inventory"
[ ! -d "$PI_DIR/extensions" ] || [ -z "$(find "$PI_DIR/extensions" -mindepth 1 -print -quit)" ] || fail "isolated Pi home unexpectedly has global extensions"

# Negative control: a distinct watcher copy must still conflict with the
# auto-discovered tracked watcher, proving this test detects duplicate sources.
cp "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/distinct-watch-copy.ts"
set +e
negative_output=$(cd "$PROJECT" && PI_CODING_AGENT_DIR="$PI_DIR" PI_OFFLINE=1 FM_HOME="$PROJECT" \
  pi --approve --offline --print --no-session \
    -e "$PROJECT/.pi/extensions/distinct-watch-copy.ts" \
    'do not run' 2>&1)
negative_rc=$?
set -e
[ "$negative_rc" -eq 1 ] || fail "distinct-path watcher control exited $negative_rc instead of 1"
printf '%s\n' "$negative_output" | grep -Fq 'Tool "fm_watch_arm_pi" conflicts with' || fail "distinct-path watcher control did not report the duplicate tool"
rm -f "$PROJECT/.pi/extensions/distinct-watch-copy.ts"

WATCH="$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
PROBE="$PROJECT/state/registration-probe.ts"
cat > "$PROBE" <<'TS'
import { writeFileSync } from "node:fs";

export default function (pi: any) {
  pi.on("session_start", () => {
    const toolCount = pi.getAllTools().filter((tool: any) => tool.name === "fm_watch_arm_pi").length;
    const commandCount = pi.getCommands().filter((command: any) => command.name === "fm-watch-arm-pi").length;
    writeFileSync(
      process.env.FM_PI_REGISTRATION_PROBE,
      `pid=${process.pid}\nfm_watch_arm_pi=${toolCount}\nfm-watch-arm-pi=${commandCount}\n`,
    );
  });
}
TS

pre_restart_command="exec env PI_CODING_AGENT_DIR=$(shell_quote "$PI_DIR") PI_OFFLINE=1 $(shell_quote "$PI_BIN") --approve --offline --no-session --no-extensions --no-skills --no-context-files"
"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" "$pre_restart_command"
"$TMUX" -L "$SOCKET" set-window-option -t "$SESSION" remain-on-exit on
wait_for_text "$MODEL" 120 || fail "pre-restart Pi did not reach its interactive composer"
pre_restart_pid=$("$TMUX" -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_pid}')

launch_command=$(build_pi_launch_command "$WATCH" "$PROBE" 'Reply exactly CHARTER-ACCEPTED.')
"$TMUX" -L "$SOCKET" respawn-pane -k -t "$SESSION" -c "$PROJECT" "$launch_command"
wait_pid_dead "$pre_restart_pid" || fail "detached restart left the old Pi process $pre_restart_pid alive"
wait_for_file "$PROJECT/state/registrations.txt" 120 || fail "detached candidate did not reach session_start registration probe"

wait_for_text "CHARTER-ACCEPTED" 180 || fail "detached Pi candidate charter prompt did not complete"
wait_for_status offline || fail "fresh watcher extension did not show offline"
initial_pane=$(capture)
printf '%s\n' "$initial_pane" | grep -Fq 'Trust project folder?' && fail "--approve still produced a project trust dialog"
watch_count=$(printf '%s\n' "$initial_pane" | grep -o 'fm-primary-pi-watch.ts' | wc -l | tr -d ' ')
[ "$watch_count" -eq 1 ] || fail "same-path explicit+auto loading showed watcher extension $watch_count times"
printf '%s\n' "$initial_pane" | grep -Fq 'harness-adapters' || fail "--approve did not preserve project Firstmate skills"
candidate_pid=$("$TMUX" -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_pid}')
registrations=$(cat "$PROJECT/state/registrations.txt")
printf '%s\n' "$registrations" | grep -Fxq "pid=$candidate_pid" || fail "registration probe did not name candidate pid $candidate_pid: $registrations"
printf '%s\n' "$registrations" | grep -Fxq 'fm_watch_arm_pi=1' || fail "registration probe did not find one watcher tool: $registrations"
printf '%s\n' "$registrations" | grep -Fxq 'fm-watch-arm-pi=1' || fail "registration probe did not find one watcher command: $registrations"
marker_version=$(sed -n '1p' "$PROJECT/state/.pi-watch-extension-loaded")
marker_pid=$(sed -n '2p' "$PROJECT/state/.pi-watch-extension-loaded")
expected_version=$(shasum -a 256 "$WATCH" | awk '{print "sha256:" $1}')
[ "$marker_version" = "$expected_version" ] || fail "loaded marker hash $marker_version did not match candidate $expected_version"
[ "$marker_pid" = "$candidate_pid" ] || fail "loaded marker pid $marker_pid did not match detached candidate $candidate_pid"
mkdir -p "$LAB/fakebin"
cat > "$LAB/fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/fakebin/tmux"
live_classification=$(PATH="$LAB/fakebin:$PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive "$1"' "$PROJECT" "$SESSION")
[ "$live_classification" = alive ] || fail "real Pi secondmate classified as $live_classification instead of alive"

# shellcheck disable=SC2016  # The detached Pi, not this test shell, expands FM_HOME.
send_prompt 'Use the bash tool exactly once. In that one command, write the shell PID followed by eight-generation process ancestry (pid, ppid, command) to "$FM_HOME/state/stock-bash-ancestry.txt", run bin/fm-session-start.sh > "$FM_HOME/state/session-start.txt", then write done to "$FM_HOME/state/session-start.done". Do not use a background-job tool. Reply exactly LOCKED.'
wait_for_file "$PROJECT/state/session-start.done" 240 || fail "stock Pi Bash session-start probe did not complete"
wait_for_text "LOCKED" 120 || fail "Pi did not acknowledge the completed session-start probe"
wait_for_file "$PROJECT/state/.lock" 40 || fail "session start did not write the fleet lock"
wait_for_file "$PROJECT/state/stock-bash-ancestry.txt" 40 || fail "stock Bash ancestry was not recorded"
wait_for_file "$PROJECT/state/session-start.txt" 40 || fail "session-start output was not recorded"
grep -Fq 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: pi' "$PROJECT/state/session-start.txt" || fail "session start did not detect Pi"
if grep -Fq 'PI_WATCH_EXTENSION: not loaded' "$PROJECT/state/session-start.txt"; then
  fail "session start rejected the current candidate hash/Pi loaded marker"
fi
pi_pid=$(tr -d '[:space:]' < "$PROJECT/state/.lock")
case "$pi_pid" in ''|*[!0-9]*) fail "fleet lock did not contain a Pi pid: $pi_pid" ;; esac
ps -p "$pi_pid" -o comm= | grep -Eq '(^|/)pi$' || fail "fleet lock pid $pi_pid is not the Pi process"
[ "$pi_pid" = "$candidate_pid" ] || fail "fleet lock owner $pi_pid did not match detached candidate $candidate_pid"
awk -v pi="$pi_pid" '$1 ~ /^[0-9]+$/ && $2 == pi && $0 ~ /bash/ { found=1 } END { exit(found ? 0 : 1) }' "$PROJECT/state/stock-bash-ancestry.txt" \
  || fail "stock Bash was not recorded as a direct Pi child"

: > "$PROJECT/state/pi-e2e.meta"
send_prompt 'Use fm_watch_arm_pi exactly once to start supervision. Never use bash to arm supervision. Reply exactly ARMED. After any FIRSTMATE WATCHER WAKE, run bin/fm-wake-drain.sh, read the signaled status, do not re-arm, and finish exactly WAKE-HANDLED.'
wait_for_text "watcher: started Pi extension arm child 1" 180 || fail "native Pi tool did not arm supervision"
wait_for_text "ARMED" 120 || fail "Pi did not settle after initial native arm"
wait_for_status watching || fail "owned arm did not show watching"
wake_handled_before=$(text_count "WAKE-HANDLED")

printf 'done: pi live e2e watcher fire\n' > "$PROJECT/state/pi-e2e.status"
wait_for_status "handling wake" 240 || fail "delivered actionable wake did not show handling wake"
wait_for_text_count_after "WAKE-HANDLED" "$wake_handled_before" 180 || fail "Pi did not settle after handling the watcher wake"

send_prompt 'Use fm_watch_arm_pi exactly once to resume supervision after the handled wake. Do not use bash. Reply exactly REARMED.'
wait_for_text "watcher: started Pi extension arm child 2" 180 || fail "separate native re-arm did not start a new coordinator generation"
wait_for_text "REARMED" 180 || fail "Pi did not settle after the separate re-arm"
wait_for_status watching 180 || fail "successful re-arm did not restore watching"
wait_for_settled_composer || fail "Pi composer did not settle before reload"

before_reload=$(capture)
false_failure_count=$(printf '%s\n' "$before_reload" | grep -Fc 'FIRSTMATE WATCHER WAKE: watcher: FAILED' || true)
[ "$false_failure_count" -eq 0 ] || fail "watcher failure appeared before reload"
pid_file=$(find "$PROJECT/state" -maxdepth 3 -type f -name pid | head -1)
[ -n "$pid_file" ] || fail "re-armed watcher pid was not recorded"
watcher_pid=$(sed -n '1p' "$pid_file")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "re-armed watcher parent was not live"
arm_pgid=$(ps -p "$arm_pid" -o pgid= | tr -d ' ')
watcher_pgid=$(ps -p "$watcher_pid" -o pgid= | tr -d ' ')
[ "$arm_pgid" = "$arm_pid" ] || fail "native arm $arm_pid did not own its detached process group $arm_pgid"
[ "$watcher_pgid" = "$arm_pgid" ] || fail "watcher $watcher_pid escaped native arm process group $arm_pgid"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/reload'
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_status_absent 40 || fail "reload did not clear the old watcher status"
wait_for_text "Reloaded keybindings" 120 || fail "Pi reload did not complete"
wait_for_status offline 120 || fail "reloaded watcher instance did not start offline"
wait_pid_dead "$watcher_pid" || fail "intentional reload left the old watcher alive"
wait_pid_dead "$arm_pid" || fail "intentional reload left the old arm child alive"
after_reload=$(capture)
after_false_count=$(printf '%s\n' "$after_reload" | grep -Fc 'FIRSTMATE WATCHER WAKE: watcher: FAILED' || true)
[ "$after_false_count" -eq "$false_failure_count" ] || fail "intentional reload injected a false watcher failure"
printf '%s\n' "$after_reload" | grep -Fq 'fm-watch-arm.sh exited 143' && fail "intentional reload exposed exit 143"

send_prompt 'Use fm_watch_arm_pi exactly once to resume supervision after reload. Do not use bash. Reply exactly RELOAD-REARMED.'
wait_for_text "watcher: started Pi extension arm child 3" 180 || fail "post-reload native arm did not start a new coordinator generation"
wait_for_text "RELOAD-REARMED" 120 || fail "Pi did not settle after post-reload re-arm"
wait_for_status watching 180 || fail "post-reload native arm did not show watching"
wait_for_settled_composer || fail "Pi composer did not settle before quit"
new_pid_file=$(find "$PROJECT/state" -maxdepth 3 -type f -name pid | head -1)
new_watcher_pid=$(sed -n '1p' "$new_pid_file")
new_arm_pid=$(ps -p "$new_watcher_pid" -o ppid= | tr -d ' ')
[ "$new_watcher_pid" != "$watcher_pid" ] || fail "post-reload watcher reused the old pid"

capture > "$LAB/final-pane.txt"
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_status_absent 40 || fail "quit did not clear the watcher status"
wait_for_pi_exit_zero || fail "Pi did not exit cleanly with status 0"
wait_pid_dead "$new_watcher_pid" || fail "watcher child survived clean Pi exit"
wait_pid_dead "$new_arm_pid" || fail "arm child survived clean Pi exit"
wait_pid_dead "$candidate_pid" || fail "detached candidate Pi survived clean quit"
if pgrep -P "$pre_restart_pid" >/dev/null 2>&1 || pgrep -P "$candidate_pid" >/dev/null 2>&1; then
  fail "a Pi descendant survived detached restart or clean quit"
fi
orphan_pi=$(ps -axo pid=,comm=,command= | awk -v lab="$LAB" 'index($0, lab) && ($2 ~ /(^|\/)pi$/ || ($2 ~ /node/ && $0 ~ /pi-coding-agent/)) { print }')
[ -z "$orphan_pi" ] || fail "an orphan Pi process still references the owned lab: $orphan_pi"

printf 'evidence - role=%s candidate_hash=%s candidate_pid=%s lock_pid=%s arm_pgid=%s watcher_pid=%s old_pi_pid=%s all_clean=true\n' \
  "$ROLE" "$expected_version" "$candidate_pid" "$pi_pid" "$arm_pgid" "$watcher_pid" "$pre_restart_pid"
printf 'ok - Pi %s %s watcher status moved offline -> watching -> handling wake -> watching, reloaded to offline, and cleared with clean process shutdown\n' "$PI_VERSION" "$ROLE"
