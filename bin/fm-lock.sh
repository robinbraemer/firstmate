#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Competing acquisitions are serialized, stale holders are reclaimed, and the
# winning PID is published atomically without overwriting a live owner.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_MUTEX="$STATE/.lock.acquire"
LOCK_MUTEX_STALE_AFTER=10
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-process-lib.sh
. "$SCRIPT_DIR/fm-process-lib.sh"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

process_is_harness() {
  local pid=$1 comm args comm_base
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  comm=${comm#-}
  comm_base=${comm##*/}
  if printf '%s' "$comm_base" | grep -qE "$HARNESS_RE"; then
    return 0
  fi
  if fm_process_is_pi "$comm" "$args"; then
    return 0
  fi
  case "$comm_base" in
    node*)
      printf '%s' "$args" | grep -qE "$HARNESS_RE"
      ;;
    python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" ;;
    *) return 1 ;;
  esac
}

harness_pid() {
  local pid=$$
  for _ in 1 2 3 4 5 6 7 8; do
    if process_is_harness "$pid"; then
      echo "$pid"; return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1
  kill -0 "$pid" 2>/dev/null || return 1
  process_is_harness "$pid"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if ! fm_lock_try_acquire "$LOCK_MUTEX" "$LOCK_MUTEX_STALE_AFTER"; then
  echo "error: another session lock acquisition is in progress; retry before mutating fleet state" >&2
  exit 1
fi
lock_mutex_held=1
lock_tmp=
cleanup_lock_claim() {
  [ -n "$lock_tmp" ] && rm -f "$lock_tmp" 2>/dev/null || true
  if [ "$lock_mutex_held" -eq 1 ]; then
    fm_lock_release "$LOCK_MUTEX"
    lock_mutex_held=0
  fi
}
trap cleanup_lock_claim EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
lock_tmp=$(mktemp "$STATE/.lock.write.XXXXXX") || { echo "error: cannot prepare session lock record" >&2; exit 1; }
printf '%s\n' "$me" > "$lock_tmp" || { echo "error: cannot write session lock record" >&2; exit 1; }
mv "$lock_tmp" "$LOCK" || { echo "error: cannot publish session lock record" >&2; exit 1; }
lock_tmp=
[ "$(cat "$LOCK" 2>/dev/null || true)" = "$me" ] || { echo "error: session lock ownership could not be confirmed" >&2; exit 1; }
echo "lock acquired: harness pid $me"
