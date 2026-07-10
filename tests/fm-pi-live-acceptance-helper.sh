#!/usr/bin/env bash
# Evidence helper for the external native-Pi live-fire acceptance lane.
# It records or emits deterministic evidence only; it never starts, replaces,
# backgrounds, or stops Firstmate supervision.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ACCEPTANCE_ID=${FM_PI_ACCEPTANCE_ID:?set FM_PI_ACCEPTANCE_ID}
CANDIDATE_COMMIT=${FM_PI_CANDIDATE_COMMIT:?set FM_PI_CANDIDATE_COMMIT}
EVIDENCE=${FM_PI_ACCEPTANCE_EVIDENCE:?set FM_PI_ACCEPTANCE_EVIDENCE}
PI_DIR=${PI_CODING_AGENT_DIR:?set PI_CODING_AGENT_DIR to the isolated Pi home}
FM_HOME=${FM_HOME:?set FM_HOME to the isolated Firstmate home}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

mkdir -p "$EVIDENCE" "$STATE"

actual_commit=$(git -C "$ROOT" rev-parse HEAD)
if [ "$actual_commit" != "$CANDIDATE_COMMIT" ]; then
  printf 'error: candidate commit mismatch: expected %s, checkout is %s\n' "$CANDIDATE_COMMIT" "$actual_commit" >&2
  exit 1
fi

file_epoch() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null || printf 'unknown'
  else
    stat -c %Y "$1" 2>/dev/null || printf 'unknown'
  fi
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1"
  else
    sha256sum "$1"
  fi
}

record_process() {  # <label> <pid>
  local label=$1 pid=$2
  case "$pid" in ''|*[!0-9]*) printf '%s_pid=absent\n' "$label"; return ;; esac
  printf '%s_pid=%s\n' "$label" "$pid"
  ps -o pid=,ppid=,pgid=,state=,lstart=,command= -p "$pid" 2>/dev/null || printf '%s_process=not-live\n' "$label"
}

inventory() {
  {
    printf 'acceptance_id=%s\n' "$ACCEPTANCE_ID"
    printf 'candidate_commit=%s\n' "$CANDIDATE_COMMIT"
    printf 'checkout_commit=%s\n' "$actual_commit"
    printf 'fm_home=%s\n' "$FM_HOME"
    printf 'pi_coding_agent_dir=%s\n' "$PI_DIR"
    printf 'pi_version=%s\n' "$(pi --version 2>&1)"
  } > "$EVIDENCE/identity.txt"
  PI_CODING_AGENT_DIR="$PI_DIR" PI_OFFLINE=1 pi list > "$EVIDENCE/pi-list.txt" 2>&1
  find "$PI_DIR" -mindepth 1 -maxdepth 4 -print | LC_ALL=C sort > "$EVIDENCE/pi-agent-inventory.txt"
  hash_file "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" > "$EVIDENCE/tracked-extension-hashes.txt"
}

registrations() {  # <tool-count> <command-count> [transcript]
  local tool_count=${1:?tool registration count required} command_count=${2:?command registration count required} transcript=${3:-}
  [ "$tool_count" = 1 ] || { printf 'error: expected one fm_watch_arm_pi registration, got %s\n' "$tool_count" >&2; exit 1; }
  [ "$command_count" = 1 ] || { printf 'error: expected one fm-watch-arm-pi registration, got %s\n' "$command_count" >&2; exit 1; }
  {
    printf 'fm_watch_arm_pi=%s\n' "$tool_count"
    printf 'fm-watch-arm-pi=%s\n' "$command_count"
  } > "$EVIDENCE/registrations.txt"
  if [ -n "$transcript" ]; then
    cp "$transcript" "$EVIDENCE/registration-transcript.txt"
  fi
}

snapshot() {  # <phase>
  local phase=${1:?snapshot phase required} watcher_pid='' arm_pid='' pi_pid='' beat_epoch='' beat_age='' now
  [ -f "$STATE/.lock" ] && pi_pid=$(tr -d '[:space:]' < "$STATE/.lock")
  [ -f "$STATE/.watch.lock/pid" ] && watcher_pid=$(tr -d '[:space:]' < "$STATE/.watch.lock/pid")
  case "$watcher_pid" in ''|*[!0-9]*) arm_pid= ;; *) arm_pid=$(ps -o ppid= -p "$watcher_pid" 2>/dev/null | tr -d '[:space:]' || true) ;; esac
  if [ -f "$STATE/.last-watcher-beat" ]; then
    beat_epoch=$(file_epoch "$STATE/.last-watcher-beat")
    now=$(date +%s)
    case "$beat_epoch" in ''|*[!0-9]*) beat_age=unknown ;; *) beat_age=$((now - beat_epoch)) ;; esac
  else
    beat_epoch=absent
    beat_age=absent
  fi
  {
    printf 'acceptance_id=%s\n' "$ACCEPTANCE_ID"
    printf 'candidate_commit=%s\n' "$CANDIDATE_COMMIT"
    printf 'phase=%s\n' "$phase"
    printf 'watcher_pid=%s\n' "${watcher_pid:-absent}"
    printf 'fm_home=%s\n' "$(cat "$STATE/.watch.lock/fm-home" 2>/dev/null || printf 'absent')"
    printf 'watcher_path=%s\n' "$(cat "$STATE/.watch.lock/watcher-path" 2>/dev/null || printf 'absent')"
    printf 'pid_identity=%s\n' "$(cat "$STATE/.watch.lock/pid-identity" 2>/dev/null || printf 'absent')"
    printf 'beacon_epoch=%s\n' "$beat_epoch"
    printf 'beacon_age_seconds=%s\n' "$beat_age"
  } > "$EVIDENCE/$phase-watcher-lock.txt"
  {
    record_process pi "$pi_pid"
    record_process arm "$arm_pid"
    record_process watcher "$watcher_pid"
  } > "$EVIDENCE/$phase-process-tree.txt"
  if [ -n "${FM_PI_ACCEPTANCE_TRANSCRIPT:-}" ] && [ -f "$FM_PI_ACCEPTANCE_TRANSCRIPT" ]; then
    cp "$FM_PI_ACCEPTANCE_TRANSCRIPT" "$EVIDENCE/$phase-transcript.txt"
  fi
}

emit_status() {  # <task-id>
  local task_id=${1:?task id required} text
  case "$task_id" in ''|*[!a-zA-Z0-9-]*) printf 'error: unsafe task id: %s\n' "$task_id" >&2; exit 1 ;; esac
  text="done: Pi live acceptance $ACCEPTANCE_ID at candidate $CANDIDATE_COMMIT"
  printf 'kind=scout\nwindow=acceptance:%s\n' "$task_id" > "$STATE/$task_id.meta"
  printf '%s\n' "$text" > "$STATE/$task_id.status"
  printf '%s\n' "$text" > "$EVIDENCE/emitted-status.txt"
}

drain_queue() {
  "$ROOT/bin/fm-wake-drain.sh" 2>&1 | tee "$EVIDENCE/queue-drain.txt"
}

record_transcript() {  # <phase> <path>
  local phase=${1:?transcript phase required} path=${2:?transcript path required}
  [ -f "$path" ] || { printf 'error: transcript not found: %s\n' "$path" >&2; exit 1; }
  cp "$path" "$EVIDENCE/$phase-transcript.txt"
}

verify_reload() {  # <path>
  local path=${1:?reload transcript path required}
  [ -f "$path" ] || { printf 'error: transcript not found: %s\n' "$path" >&2; exit 1; }
  cp "$path" "$EVIDENCE/reload-transcript.txt"
  if grep -Fq 'FIRSTMATE WATCHER WAKE: watcher: FAILED' "$path"; then
    printf 'error: Pi reload transcript contains a false watcher failure\n' >&2
    exit 1
  fi
  printf 'watcher_only_reload=clean\n' > "$EVIDENCE/reload-check.txt"
}

verify_clean() {  # <arm-pid> <watcher-pid>
  local arm_pid=${1:?arm pid required} watcher_pid=${2:?watcher pid required} failed=0
  {
    printf 'acceptance_id=%s\n' "$ACCEPTANCE_ID"
    printf 'candidate_commit=%s\n' "$CANDIDATE_COMMIT"
    if kill -0 "$arm_pid" 2>/dev/null; then printf 'arm_pid_%s=alive\n' "$arm_pid"; failed=1; else printf 'arm_pid_%s=dead\n' "$arm_pid"; fi
    if kill -0 "$watcher_pid" 2>/dev/null; then printf 'watcher_pid_%s=alive\n' "$watcher_pid"; failed=1; else printf 'watcher_pid_%s=dead\n' "$watcher_pid"; fi
  } > "$EVIDENCE/clean-exit.txt"
  [ "$failed" -eq 0 ]
}

case "${1:-}" in
  inventory) inventory ;;
  registrations) shift; registrations "$@" ;;
  snapshot) shift; snapshot "$@" ;;
  emit) shift; emit_status "$@" ;;
  drain) drain_queue ;;
  transcript) shift; record_transcript "$@" ;;
  verify-reload) shift; verify_reload "$@" ;;
  verify-clean) shift; verify_clean "$@" ;;
  *)
    printf 'usage: %s inventory|registrations <tool-count> <command-count> [transcript]|snapshot <phase>|emit <task-id>|drain|transcript <phase> <path>|verify-reload <path>|verify-clean <arm-pid> <watcher-pid>\n' "$0" >&2
    exit 2
    ;;
esac
