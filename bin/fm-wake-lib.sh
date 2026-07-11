#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.
# Lock identity prefers Linux /proc start ticks, falls back to locale-stable
# ps output elsewhere, and reads the earlier untagged ps format compatibly.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
mkdir -p "$STATE"

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# Parse Linux /proc/<pid>/stat field 22 (process start ticks since boot).
# Removing through the final ") " keeps spaces and parentheses in comm safe.
fm_pid_start_ticks_from_proc_stat() {
  local stat=$1 out
  out=$(printf '%s\n' "$stat" | sed 's/^.*) //' | awk '$20 ~ /^[0-9]+$/ { print $20; exit }')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

fm_pid_start_ticks_from_proc() {
  local pid=$1 stat
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -r "/proc/$pid/stat" ] || return 1
  stat=
  IFS= read -r stat < "/proc/$pid/stat" || return 1
  fm_pid_start_ticks_from_proc_stat "$stat"
}

fm_linux_boot_id() {
  local boot_id=
  [ -r /proc/sys/kernel/random/boot_id ] || return 1
  IFS= read -r boot_id < /proc/sys/kernel/random/boot_id || return 1
  case "$boot_id" in
    ''|*[!0-9A-Fa-f-]*) return 1 ;;
  esac
  printf '%s\n' "$boot_id"
}

fm_pid_identity_from_proc() {
  local pid=$1 start_ticks boot_id
  start_ticks=$(fm_pid_start_ticks_from_proc "$pid") || return 1
  boot_id=$(fm_linux_boot_id) || return 1
  printf 'proc:%s:%s\n' "$boot_id" "$start_ticks"
}

# Return the pre-tag process identity format used on platforms without /proc.
fm_pid_legacy_identity() {
  local pid=$1 out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

# Return a tagged process identity: stable monotonic start ticks on Linux/WSL2,
# or locale-pinned wall-clock start plus command on other platforms.
fm_pid_identity() {
  local pid=$1 identity
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  identity=$(fm_pid_identity_from_proc "$pid" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    printf '%s\n' "$identity"
    return 0
  fi
  identity=$(fm_pid_legacy_identity "$pid") || return 1
  printf 'ps:%s\n' "$identity"
}

# Return 0 for a match, 1 for an authoritative tagged mismatch, and 2 when a
# legacy mismatch or unavailable probe cannot safely disprove live ownership.
fm_pid_identity_matches() {
  local pid=$1 recorded_identity=$2 current_identity current_ticks recorded_ticks tagged=
  [ -n "$recorded_identity" ] || return 2
  case "$recorded_identity" in
    proc:*:*)
      tagged=1
      current_identity=$(fm_pid_identity_from_proc "$pid" 2>/dev/null || true)
      ;;
    proc:*)
      recorded_ticks=${recorded_identity#proc:}
      case "$recorded_ticks" in
        ''|*[!0-9]*) return 2 ;;
      esac
      current_ticks=$(fm_pid_start_ticks_from_proc "$pid" 2>/dev/null || true)
      [ -n "$current_ticks" ] || return 2
      [ "$current_ticks" = "$recorded_ticks" ] && return 2
      return 1
      ;;
    ps:*)
      tagged=1
      current_identity=$(fm_pid_legacy_identity "$pid" 2>/dev/null || true)
      [ -n "$current_identity" ] && current_identity="ps:$current_identity"
      ;;
    *)
      current_identity=$(fm_pid_legacy_identity "$pid" 2>/dev/null || true)
      ;;
  esac
  [ -n "$current_identity" ] || return 2
  [ "$current_identity" = "$recorded_identity" ] && return 0
  [ -n "$tagged" ] && return 1
  return 2
}

fm_path_mtime() {
  local mtime
  mtime=$(stat -c %Y "$1" 2>/dev/null || true)
  case "$mtime" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$mtime"; return 0 ;;
  esac
  mtime=$(stat -f %m "$1" 2>/dev/null || true)
  case "$mtime" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$mtime" ;;
  esac
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  fm_pid_identity_matches "$pid" "$lock_identity"
}

FM_WATCHER_HEALTHY_PID=
fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir beat pid age
  FM_WATCHER_HEALTHY_PID=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home" || return 1
  age=$(fm_path_age "$beat")
  [ "$age" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  return 0
}

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_prepare_owner() {
  local ownerdir=$1 require_identity=${2:-} mypid identity back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ] || return 1
  identity=$(fm_pid_identity "$mypid" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    printf '%s\n' "$identity" > "$ownerdir/pid-identity" 2>/dev/null || return 1
  elif [ -n "$require_identity" ]; then
    return 2
  fi
}

fm_lock_link_owner() {
  local lockdir=$1 owner
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

fm_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  fm_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} require_identity=${3:-} ownerdir rc
  FM_LOCK_OWNER_DIR=
  ownerdir=$(fm_lock_owner_dir "$lockdir") || return 1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  fm_lock_prepare_owner "$ownerdir" "$require_identity"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_lock_discard_owner "$ownerdir"
    return "$rc"
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_live_owner_is_fresh() {
  local lockdir=$1 pid=$2 live_stale_after=${3:-} recorded_identity identity_rc
  fm_pid_alive "$pid" || return 1
  recorded_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  if [ -n "$recorded_identity" ]; then
    fm_pid_identity_matches "$pid" "$recorded_identity" && return 0
    identity_rc=$?
    [ "$identity_rc" -eq 2 ] && return 0
    return 1
  fi
  [ -n "$live_stale_after" ] || return 0
  [ "$(fm_path_age "$lockdir")" -lt "$live_stale_after" ]
}

fm_lock_owned_by_current_process() {
  local lockdir=$1 expected_owner=${2:-} ownerdir pid recorded_identity current
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 1
    [ -z "$expected_owner" ] || [ "$ownerdir" = "$expected_owner" ] || return 1
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 1
  else
    [ -z "$expected_owner" ] || return 1
    ownerdir=$lockdir
  fi
  pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 1
  recorded_identity=$(cat "$ownerdir/pid-identity" 2>/dev/null || true)
  [ -n "$recorded_identity" ] || return 1
  fm_pid_identity_matches "$current" "$recorded_identity"
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 live_stale_after=${4:-} actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_lock_live_owner_is_fresh "$lockdir" "$actual_pid" "$live_stale_after"; then
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

fm_lock_try_acquire() {
  local lockdir=$1 live_stale_after=${2:-} pid steal cur rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=

  fm_lock_try_create "$lockdir" "" "$live_stale_after"
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 2 ] && return 1

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_lock_live_owner_is_fresh "$lockdir" "$pid" "$live_stale_after"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! fm_lock_try_acquire "$steal" "$live_stale_after"; then
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_lock_live_owner_is_fresh "$lockdir" "$cur" "$live_stale_after"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur" "$live_stale_after"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  fm_lock_remove_path "$lockdir" || true
  rc=1
  if fm_lock_try_create "$lockdir" "$steal_owner" "$live_stale_after"; then
    rc=0
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release "$steal"
  return "$rc"
}

fm_lock_acquire_wait() {
  local lockdir=$1
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

fm_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}
