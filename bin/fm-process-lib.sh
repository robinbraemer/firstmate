#!/usr/bin/env bash
# Shared process-snapshot classifiers for lock ownership and backend liveness.

fm_process_pi_proc_argv() {  # <pid>
  local pid=$1 index=0 arg argv0_base
  [ -r "/proc/$pid/cmdline" ] || return 2
  while IFS= read -r -d '' arg; do
    case "$index" in
      0)
        argv0_base=${arg##*/}
        case "$argv0_base" in node*) ;; *) return 1 ;; esac
        ;;
      1)
        case "$arg" in
          */@earendil-works/pi-coding-agent/dist/cli.js) return 0 ;;
          *) return 1 ;;
        esac
        ;;
    esac
    index=$((index + 1))
  done < "/proc/$pid/cmdline"
  return 2
}

fm_process_pi_installed_entrypoint() {
  local path target i=0
  path=$(command -v pi 2>/dev/null) || return 1
  while [ -L "$path" ] && [ "$i" -lt 8 ]; do
    target=$(readlink "$path") || return 1
    case "$target" in
      /*) path=$target ;;
      *) path=$(cd "$(dirname "$path")" && cd "$(dirname "$target")" && pwd -P)/$(basename "$target") ;;
    esac
    i=$((i + 1))
  done
  case "$path" in
    */@earendil-works/pi-coding-agent/dist/cli.js) printf '%s\n' "$path" ;;
    *) return 1 ;;
  esac
}

fm_process_pi_command_path() {
  local path dir
  path=$(command -v pi 2>/dev/null) || return 1
  dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

fm_process_is_pi() {  # <pid> <comm> <args>
  local pid=$1 comm=$2 args=$3 comm_base argv0 argv_base rest script proc_rc command_path entrypoint node_path prefix
  comm=${comm#-}
  comm_base=${comm##*/}
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  argv_base=${argv0##*/}

  if [ "$comm_base" = pi ]; then
    [ "$argv_base" = pi ] && return 0
    command_path=$(fm_process_pi_command_path 2>/dev/null || true)
    if [ -n "$command_path" ]; then
      case "$args" in "$command_path"|"$command_path "*) return 0 ;; esac
    fi
    return 1
  fi

  case "$comm_base:$argv_base" in node*:node*) ;; *) return 1 ;; esac
  rest=${args#"$argv0"}
  rest=${rest#"${rest%%[![:space:]]*}"}
  script=${rest%%[[:space:]]*}
  case "$script" in
    */@earendil-works/pi-coding-agent/dist/cli.js) return 0 ;;
  esac

  fm_process_pi_proc_argv "$pid"
  proc_rc=$?
  [ "$proc_rc" -eq 0 ] && return 0
  [ "$proc_rc" -eq 1 ] && return 1

  entrypoint=$(fm_process_pi_installed_entrypoint 2>/dev/null || true)
  if [ -n "$entrypoint" ]; then
    for node_path in "$comm" "$(command -v node 2>/dev/null || true)"; do
      [ -n "$node_path" ] || continue
      prefix="$node_path $entrypoint"
      case "$args" in "$prefix"|"$prefix "*) return 0 ;; esac
    done
  fi
  return 1
}
