#!/usr/bin/env bash
# Shared process-snapshot classifiers for lock ownership and backend liveness.

fm_process_is_pi() {  # <comm> <args>
  local comm=$1 args=$2 comm_base argv0 argv_base rest script
  comm=${comm#-}
  comm_base=${comm##*/}
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  argv_base=${argv0##*/}

  if [ "$comm_base" = pi ] && [ "$argv_base" = pi ]; then
    return 0
  fi
  case "$comm_base:$argv_base" in
    node*:node*) ;;
    *) return 1 ;;
  esac
  rest=${args#"$argv0"}
  rest=${rest#"${rest%%[![:space:]]*}"}
  script=${rest%%[[:space:]]*}
  case "$script" in
    */@earendil-works/pi-coding-agent/dist/cli.js) return 0 ;;
  esac
  return 1
}
