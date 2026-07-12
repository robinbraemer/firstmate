#!/usr/bin/env bash
# Launch the isolated Pi live-regression candidate with exact argv and no
# intermediate process. The tmux test replaces its old pane process with this
# helper, and this helper immediately execs Pi so no nested Pi can survive.
# Usage: fm-pi-detached-launch-helper.sh <pi> <pi-dir> <fm-home> <watch> <probe> <prompt>
set -eu

[ "$#" -eq 6 ] || {
  printf 'usage: %s <pi> <pi-dir> <fm-home> <watch> <probe> <prompt>\n' "$0" >&2
  exit 2
}

PI_BIN=$1
PI_DIR=$2
FM_HOME_ARG=$3
WATCH=$4
PROBE=$5
PROMPT=$6

exec env \
  PI_CODING_AGENT_DIR="$PI_DIR" \
  FM_HOME="$FM_HOME_ARG" \
  FM_ROOT_OVERRIDE="$FM_HOME_ARG" \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=0 \
  FM_HEARTBEAT=600 \
  PI_OFFLINE=1 \
  FM_PI_REGISTRATION_PROBE="$FM_HOME_ARG/state/registrations.txt" \
  "$PI_BIN" \
  --approve \
  --offline \
  --no-session \
  --verbose \
  -e "$WATCH" \
  -e "$PROBE" \
  "$PROMPT"
