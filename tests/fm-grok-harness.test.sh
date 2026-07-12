#!/usr/bin/env bash
# Behavior tests for Grok-harness hook authentication, teardown cleanup, and session-lock holder detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-harness)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$grok_home"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" grok 2>&1
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin grok_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$grok_home/hooks/fm-turn-end.sh"
  assert_present "$hook" "grok hook script was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" "grok auth registry entry was not written"

  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$evil" bash "$hook"
  assert_absent "$evil_target" "old-style grok pointer touched an arbitrary target"

  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_absent "$target" "grok pointer accepted token outside the first line"

  printf 'token=%s\n' "$token" > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_present "$target" "registered grok pointer did not touch the task turn-end file"
  pass "grok global hook requires a firstmate registry token"
}

test_grok_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin grok_home id out status token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok teardown failed"

  assert_absent "$wt/.fm-grok-turnend" "grok pointer survived teardown"
  assert_absent "$grok_home/hooks/fm-turn-end.d/$token" "grok auth token survived teardown"
  assert_absent "$home/state/$id.grok-turnend-token" "grok state token survived teardown"
  pass "grok teardown removes pointer and token state"
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/grok'; exit 0 ;;
  *"args="*) printf '%s\n' 'grok'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize grok as a live holder"
  pass "fm-lock recognizes grok harness processes"
}

test_fm_lock_recognizes_pi_holder() {
  local home fakebin out
  home="$TMP_ROOT/pi-lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/pi-lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/pi'; exit 0 ;;
  *"args="*) printf '%s\n' 'pi --approve'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize Pi as a live holder"
  pass "fm-lock recognizes Pi harness processes"
}

test_fm_lock_serializes_claims() {
  local case_dir home fakebin real_mkdir real_cat racer go release result_one result_two pid_one pid_two code_one code_two winners lock_pid i
  case_dir="$TMP_ROOT/pi-lock-race"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  racer="$case_dir/pi-coding-agent-racer.mjs"
  go="$case_dir/go"
  release="$case_dir/release"
  result_one="$case_dir/one.json"
  result_two="$case_dir/two.json"
  mkdir -p "$home/state" "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  real_mkdir=$(command -v mkdir)
  real_cat=$(command -v cat)
cat > "$fakebin/mkdir" <<'SH'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last=$arg; done
if [ "$last" = "$FM_RACE_CLAIM" ]; then
  if "$FM_REAL_MKDIR" "$@"; then
    sleep 2
    exit 0
  fi
  exit 1
fi
exec "$FM_REAL_MKDIR" "$@"
SH
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "$FM_RACE_LOCK" ]; then
  attempts=0
  "$FM_REAL_MKDIR" "$FM_RACE_CAT_DIR/$$"
  while [ "$attempts" -lt 100 ] && [ "$(find "$FM_RACE_CAT_DIR" -type d | wc -l | tr -d ' ')" -lt 3 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
fi
exec "$FM_REAL_CAT" "$@"
SH
  chmod +x "$fakebin/mkdir"
  chmod +x "$fakebin/cat"
  cat > "$racer" <<'JS'
import { existsSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

while (!existsSync(process.env.FM_RACE_GO)) await new Promise((resolve) => setTimeout(resolve, 5));
const result = spawnSync(process.env.FM_LOCK_SCRIPT, [], { encoding: "utf8", env: process.env });
writeFileSync(process.env.FM_RACE_RESULT, JSON.stringify({ pid: process.pid, code: result.status, stdout: result.stdout, stderr: result.stderr }));
while (!existsSync(process.env.FM_RACE_RELEASE)) await new Promise((resolve) => setTimeout(resolve, 5));
JS
  mkdir -p "$case_dir/cat-barrier"
  FM_HOME="$home" FM_RACE_CLAIM="$home/state/.lock.claim" FM_RACE_LOCK="$home/state/.lock" \
    FM_RACE_CAT_DIR="$case_dir/cat-barrier" FM_REAL_MKDIR="$real_mkdir" FM_REAL_CAT="$real_cat" \
    FM_RACE_GO="$go" FM_RACE_RELEASE="$release" FM_RACE_RESULT="$result_one" \
    FM_LOCK_SCRIPT="$ROOT/bin/fm-lock.sh" PATH="$fakebin:$PATH" node "$racer" &
  pid_one=$!
  FM_HOME="$home" FM_RACE_CLAIM="$home/state/.lock.claim" FM_RACE_LOCK="$home/state/.lock" \
    FM_RACE_CAT_DIR="$case_dir/cat-barrier" FM_REAL_MKDIR="$real_mkdir" FM_REAL_CAT="$real_cat" \
    FM_RACE_GO="$go" FM_RACE_RELEASE="$release" FM_RACE_RESULT="$result_two" \
    FM_LOCK_SCRIPT="$ROOT/bin/fm-lock.sh" PATH="$fakebin:$PATH" node "$racer" &
  pid_two=$!
  : > "$go"
  i=0
  while [ "$i" -lt 500 ] && { [ ! -f "$result_one" ] || [ ! -f "$result_two" ]; }; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -f "$result_one" ] && [ -f "$result_two" ] || {
    : > "$release"
    wait "$pid_one" "$pid_two" 2>/dev/null || true
    fail "concurrent Pi lock claims did not finish"
  }
  code_one=$(jq -r .code "$result_one")
  code_two=$(jq -r .code "$result_two")
  winners=0
  [ "$code_one" -eq 0 ] && winners=$((winners + 1))
  [ "$code_two" -eq 0 ] && winners=$((winners + 1))
  [ "$winners" -eq 1 ] || {
    : > "$release"
    wait "$pid_one" "$pid_two" 2>/dev/null || true
    fail "concurrent Pi lock claims produced $winners winners: $(cat "$result_one") $(cat "$result_two")"
  }
  lock_pid=$(cat "$home/state/.lock")
  if [ "$code_one" -eq 0 ]; then
    [ "$lock_pid" = "$(jq -r .pid "$result_one")" ] || fail "losing claim overwrote the first winner"
  else
    [ "$lock_pid" = "$(jq -r .pid "$result_two")" ] || fail "losing claim overwrote the second winner"
  fi
  : > "$release"
  wait "$pid_one" "$pid_two"
  pass "fm-lock serializes concurrent Pi claims without overwriting the winner"
}

test_fm_lock_refuses_uninitialized_live_claim() {
  local case_dir home fakebin holder ready release out code holder_pid i
  case_dir="$TMP_ROOT/pi-lock-uninitialized"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  holder="$case_dir/pi-coding-agent-uninitialized.mjs"
  ready="$case_dir/ready"
  release="$case_dir/release"
  mkdir -p "$home/state" "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/pi'; exit 0 ;;
  *"args="*) printf '%s\n' 'pi --approve'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  cat > "$holder" <<'JS'
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
mkdirSync(process.env.FM_RACE_CLAIM);
writeFileSync(process.env.FM_RACE_READY, "ready\n");
while (!existsSync(process.env.FM_RACE_RELEASE)) await new Promise((resolve) => setTimeout(resolve, 5));
JS
  FM_RACE_CLAIM="$home/state/.lock.claim" FM_RACE_READY="$ready" FM_RACE_RELEASE="$release" node "$holder" &
  holder_pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -f "$ready" ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -f "$ready" ] || fail "uninitialized live claim holder did not start"
  if out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1); then
    code=0
  else
    code=$?
  fi
  : > "$release"
  wait "$holder_pid"
  [ "$code" -ne 0 ] || fail "fm-lock removed an uninitialized live claim and acquired it: $out"
  assert_absent "$home/state/.lock" "refused uninitialized claim still overwrote the session lock"
  pass "fm-lock refuses an uninitialized live claim"
}

test_fm_lock_recovers_stale_uninitialized_claims() {
  local home fakebin out kind
  home="$TMP_ROOT/pi-lock-stale-uninitialized"
  fakebin=$(fm_fakebin "$TMP_ROOT/pi-lock-stale-uninitialized-fake")
  mkdir -p "$home/state" "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/pi'; exit 0 ;;
  *"args="*) printf '%s\n' 'pi --approve'; exit 0 ;;
  *"ppid="*) printf '%s\n' '1'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  for kind in ownerless malformed; do
    rm -rf "$home/state/.lock.claim" "$home/state/.lock.claim".owner.*
    mkdir "$home/state/.lock.claim"
    [ "$kind" = ownerless ] || printf 'not-a-pid\n' > "$home/state/.lock.claim/pid"
    touch -t 200001010000 "$home/state/.lock.claim"
    out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1) \
      || fail "fm-lock did not recover a stale $kind claim: $out"
    assert_contains "$out" "lock acquired" "fm-lock did not acquire after stale $kind recovery"
    assert_present "$home/state/.lock" "stale $kind recovery did not write the session lock"
  done
  pass "fm-lock recovers stale ownerless and malformed claims"
}

test_grok_hook_requires_registered_token
test_grok_teardown_removes_pointer_and_token
test_fm_lock_recognizes_grok_holder
test_fm_lock_recognizes_pi_holder
test_fm_lock_serializes_claims
test_fm_lock_refuses_uninitialized_live_claim
test_fm_lock_recovers_stale_uninitialized_claims
