#!/usr/bin/env bash
# Tests for the tracked Pi primary watcher extension and Pi secondmate wiring.
set -u

# Pi watcher status spec coverage:
#  1 test_pi_status_loads_offline_before_arm
#  2 test_pi_status_successful_arm_watching
#  3 test_pi_status_actionable_wake_and_rearm
#  4 test_pi_status_attention_failures
#  5 test_pi_status_intentional_stop_offline
#  6 test_pi_status_reload_and_quit_clear
#  7 test_pi_status_duplicate_arm_preserves_watching
#  8 test_pi_status_stale_generation_cannot_overwrite
#  9 test_pi_status_cancelled_start_stays_cleared
# 10 test_pi_status_absent_in_task_worktree
# 11 test_pi_status_static_non_goals

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-watch-extension)
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p "$repo/.pi/extensions" "$repo/node_modules/typebox"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

install_pi_status_harness() {
  local repo=$1
  cat > "$repo/status-harness.mjs" <<'JS'
export const makeStatusHarness = () => {
  const handlers = new Map();
  const writes = [];
  const messages = [];
  let tool = null;
  const pi = {
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendMessage(message, options) {
      messages.push({ message, options });
    },
  };
  const ctx = {
    ui: {
      setStatus(key, text) {
        writes.push([key, text]);
      },
      notify() {},
    },
  };
  return { handlers, messages, pi, ctx, tool: () => tool, writes };
};
JS
}

test_pi_status_loads_offline_before_arm() {
  local repo plugin out status
  repo="$TMP_ROOT/pi-status-offline-root"
  mkdir -p "$repo/bin" "$repo/config" "$repo/state"
  install_pi_watch_extension_fixture "$repo"
  install_pi_status_harness "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  out=$(PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" STATUS_HARNESS="$repo/status-harness.mjs" \
    node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(
  pathToFileURL(process.env.STATUS_HARNESS).href,
);
const harness = makeStatusHarness();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(harness.pi);
await harness.handlers.get("session_start")?.({ type: "session_start" }, harness.ctx);
assert.deepEqual(harness.writes, [["firstmate-pi-watcher", "offline"]]);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi watcher status must load offline before the first arm"
  [ -z "$out" ] || fail "Pi offline-status test printed output: $out"
  pass "Pi watcher status loads offline before the first arm"
}

test_pi_status_successful_arm_watching() {
  local repo plugin arm_log out status
  repo="$TMP_ROOT/pi-status-watching-root"
  arm_log="$TMP_ROOT/pi-status-watching-arm.log"
  mkdir -p "$repo/bin" "$repo/config" "$repo/state"
  install_pi_watch_extension_fixture "$repo"
  install_pi_status_harness "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
trap 'exit 0' TERM
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" STATUS_HARNESS="$repo/status-harness.mjs" \
    FM_ARM_LOG="$arm_log" node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(
  pathToFileURL(process.env.STATUS_HARNESS).href,
);
const harness = makeStatusHarness();
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(harness.pi);
await harness.handlers.get("session_start")?.({ type: "session_start" }, harness.ctx);
await harness.tool().execute("status-first-arm", {}, undefined, undefined, {});
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "watching"]);
for (let i = 0; i < 100 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
assert.equal(existsSync(process.env.FM_ARM_LOG), true);
await harness.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, harness.ctx);
EOF
  )
  status=$?
  expect_code 0 "$status" "A successful current Pi watcher arm must publish watching"
  [ -z "$out" ] || fail "Pi watching-status test printed output: $out"
  pass "A successful current Pi watcher arm publishes watching"
}

test_pi_status_duplicate_arm_preserves_watching() {
  local repo plugin arm_log out status
  repo="$TMP_ROOT/pi-status-duplicate-root"
  arm_log="$TMP_ROOT/pi-status-duplicate-arm.log"
  mkdir -p "$repo/bin" "$repo/config" "$repo/state"
  install_pi_watch_extension_fixture "$repo"
  install_pi_status_harness "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
trap 'exit 0' TERM
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" STATUS_HARNESS="$repo/status-harness.mjs" \
    FM_ARM_LOG="$arm_log" node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(
  pathToFileURL(process.env.STATUS_HARNESS).href,
);
const harness = makeStatusHarness();
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(harness.pi);
await harness.handlers.get("session_start")?.({ type: "session_start" }, harness.ctx);
await harness.tool().execute("status-first-arm", {}, undefined, undefined, {});
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "watching"]);
for (let i = 0; i < 100 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
assert.equal(existsSync(process.env.FM_ARM_LOG), true);
const coordinator = [...globalThis.__firstmatePiWatchCoordinators.values()][0];
const sequenceBeforeDuplicate = coordinator.sequence;
const generationBeforeDuplicate = coordinator.generation;
const writesBeforeDuplicate = harness.writes.length;
await harness.tool().execute("status-duplicate-arm", {}, undefined, undefined, {});
assert.equal(readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length, 1);
assert.equal(harness.writes.length, writesBeforeDuplicate);
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "watching"]);
assert.equal(coordinator.sequence, sequenceBeforeDuplicate);
assert.equal(coordinator.generation, generationBeforeDuplicate);
await harness.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, harness.ctx);
EOF
  )
  status=$?
  expect_code 0 "$status" "A duplicate Pi watcher arm must preserve watching without another start or generation"
  [ -z "$out" ] || fail "Pi duplicate-arm status test printed output: $out"
  pass "A duplicate Pi watcher arm preserves watching without another start or generation"
}

test_pi_status_duplicate_factory_preserves_active_watching() {
  local repo plugin arm_log arm_ready out status
  repo="$TMP_ROOT/pi-status-duplicate-factory-root"
  arm_log="$TMP_ROOT/pi-status-duplicate-factory-arm.log"
  arm_ready="$TMP_ROOT/pi-status-duplicate-factory-arm-ready"
  mkdir -p "$repo/bin" "$repo/config" "$repo/state"
  install_pi_watch_extension_fixture "$repo"
  install_pi_status_harness "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "${FM_ARM_LOG:?}"
trap 'exit 0' TERM
: > "${FM_ARM_READY:?}"
while :; do sleep 0.01; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" STATUS_HARNESS="$repo/status-harness.mjs" \
    FM_ARM_LOG="$arm_log" FM_ARM_READY="$arm_ready" node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(pathToFileURL(process.env.STATUS_HARNESS).href);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const url = pathToFileURL(process.env.PLUGIN).href;

const globalHarness = makeStatusHarness();
const globalModule = await import(`${url}?status-factory=global`);
globalModule.default(globalHarness.pi);
await globalHarness.handlers.get("session_start")?.({ type: "session_start" }, globalHarness.ctx);
await globalHarness.tool().execute("status-global-arm", {}, undefined, undefined, {});
for (let i = 0; i < 200 && !existsSync(process.env.FM_ARM_READY); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
assert.equal(existsSync(process.env.FM_ARM_READY), true, "global-loader arm did not become ready");
assert.deepEqual(globalHarness.writes.at(-1), ["firstmate-pi-watcher", "watching"]);

const nativeHarness = makeStatusHarness();
const nativeModule = await import(`${url}?status-factory=native`);
nativeModule.default(nativeHarness.pi);
await nativeHarness.handlers.get("session_start")?.({ type: "session_start" }, nativeHarness.ctx);
assert.deepEqual(nativeHarness.writes, [["firstmate-pi-watcher", "watching"]]);

const duplicate = await nativeHarness.tool().execute(
  "status-native-duplicate-arm",
  {},
  undefined,
  undefined,
  {},
);
assert.equal(duplicate.details?.ok, true);
assert.match(duplicate.content?.[0]?.text ?? "", /healthy - Pi extension already has an arm child/);
assert.deepEqual(nativeHarness.writes.at(-1), ["firstmate-pi-watcher", "watching"]);
assert.equal(readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length, 1);

await globalHarness.handlers.get("session_shutdown")?.(
  { type: "session_shutdown", reason: "reload" },
  globalHarness.ctx,
);
assert.deepEqual(globalHarness.writes.at(-1), ["firstmate-pi-watcher", undefined]);
assert.deepEqual(nativeHarness.writes.at(-1), ["firstmate-pi-watcher", "watching"]);
await nativeHarness.handlers.get("session_shutdown")?.(
  { type: "session_shutdown", reason: "quit" },
  nativeHarness.ctx,
);
EOF
  )
  status=$?
  expect_code 0 "$status" "A simultaneously active duplicate factory must inherit the owned watching status"
  [ -z "$out" ] || fail "Pi duplicate-factory status test printed output: $out"
  pass "Pi duplicate factory preserves active watching status and one owned arm"
}

test_pi_status_legacy_coordinator_reload_compatibility() {
  local repo plugin out status
  repo="$TMP_ROOT/pi-status-legacy-reload-root"
  mkdir -p "$repo/bin" "$repo/config" "$repo/state"
  install_pi_watch_extension_fixture "$repo"
  install_pi_status_harness "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  out=$(PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" STATUS_HARNESS="$repo/status-harness.mjs" \
    node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(
  pathToFileURL(process.env.STATUS_HARNESS).href,
);
const harness = makeStatusHarness();
const legacySender = async () => {};
const legacyCoordinator = {
  current: null,
  lastCompleted: null,
  generation: 0,
  sequence: 0,
  state: "idle",
  startPromise: null,
  startCancelled: false,
  clients: new Map([[Symbol("legacy-pi-watch-client"), legacySender]]),
};
globalThis.__firstmatePiWatchCoordinators = new Map([
  [resolve(process.env.FM_HOME), legacyCoordinator],
]);

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(harness.pi);
await harness.handlers.get("session_start")?.({ type: "session_start" }, harness.ctx);
assert.deepEqual(harness.writes, [["firstmate-pi-watcher", "offline"]]);

const newestClient = [...legacyCoordinator.clients.values()].at(-1);
assert.equal(typeof newestClient, "function");
assert.equal(newestClient.sendWake, newestClient);
await newestClient("legacy callback wake", {
  generation: 1,
  kind: "actionable",
  reason: "signal: legacy callback wake",
  exitCode: 0,
  signal: null,
  truncated: false,
  stdoutTruncated: false,
  stderrTruncated: false,
});
assert.equal(harness.messages.length, 1);
assert.equal(harness.messages[0].message.customType, "firstmate-watcher-wake");
assert.match(harness.messages[0].message.content, /^FIRSTMATE WATCHER WAKE: legacy callback wake/);
assert.deepEqual(harness.messages[0].options, {
  deliverAs: "followUp",
  triggerTurn: true,
});
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi status clients must remain callable across a legacy same-process reload"
  [ -z "$out" ] || fail "Pi legacy reload-status test printed output: $out"
  pass "Pi status clients remain callable across a legacy same-process reload"
}

test_pi_status_actionable_wake_and_rearm() {
  local reason slug repo plugin reason_file out status
  for reason in \
    "signal: synthetic wake" \
    "stale: synthetic wake" \
    "check: synthetic wake" \
    "heartbeat: synthetic wake"; do
    slug=${reason%%:*}
    repo="$TMP_ROOT/pi-status-actionable-$slug-root"
    reason_file="$TMP_ROOT/pi-status-actionable-$slug.reason"
    mkdir -p "$repo/bin" "$repo/config" "$repo/state"
    install_pi_watch_extension_fixture "$repo"
    install_pi_status_harness "$repo"
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "${FM_REASON_FILE:?}" ]; then
  cat "$FM_REASON_FILE"
  rm -f "$FM_REASON_FILE"
  exit 0
fi
trap 'exit 0' TERM
while :; do sleep 0.05; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" STATUS_HARNESS="$repo/status-harness.mjs" \
      FM_REASON_FILE="$reason_file" FM_REASON="$reason" node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(
  pathToFileURL(process.env.STATUS_HARNESS).href,
);
const harness = makeStatusHarness();
harness.pi.sendUserMessage = () => {
  throw new Error("watcher wake was delivered as a user-role message");
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(harness.pi);
await harness.handlers.get("session_start")?.({ type: "session_start" }, harness.ctx);
writeFileSync(process.env.FM_REASON_FILE, `${process.env.FM_REASON}\n`);
await harness.tool().execute("status-actionable-arm", {}, undefined, undefined, {});
for (let i = 0; i < 100 && harness.messages.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
assert.equal(harness.messages.length, 1);
assert.equal(harness.messages[0].message.customType, "firstmate-watcher-wake");
assert.equal(harness.messages[0].message.display, true);
assert.match(harness.messages[0].message.content, /^FIRSTMATE WATCHER WAKE:/);
assert.deepEqual(harness.messages[0].options, {
  deliverAs: "followUp",
  triggerTurn: true,
});
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "handling wake"]);
await harness.tool().execute("status-rearm", {}, undefined, undefined, {});
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "watching"]);
await harness.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, harness.ctx);
EOF
    )
    status=$?
    expect_code 0 "$status" "Pi $slug actionable wake must publish handling wake and re-arm to watching"
    [ -z "$out" ] || fail "Pi $slug actionable-status test printed output: $out"
  done
  pass "Pi signal, stale, check, and heartbeat wakes publish handling wake and re-arm to watching"
}

test_pi_status_attention_failures() {
  local case_name repo plugin arm_log node_bin empty_path out status
  node_bin=$(command -v node)
  for case_name in \
    live-other-owner \
    recovery-no-ownership \
    spawn-enoent \
    child-error \
    empty-clean \
    nonzero \
    unexpected-signal \
    external-healthy \
    send-message-throw; do
    repo="$TMP_ROOT/pi-status-attention-$case_name-root"
    arm_log="$repo/arm.log"
    empty_path="$repo/empty-path"
    mkdir -p "$repo/bin" "$repo/config" "$repo/state" "$empty_path"
    install_pi_watch_extension_fixture "$repo"
    install_pi_status_harness "$repo"
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
    cat > "$repo/bin/fm-lock.sh" <<'SH'
#!/bin/sh
exit 0
SH
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
case "${FM_ATTENTION_CASE:?}" in
  child-error|unexpected-signal)
    trap 'exit 0' TERM
    while :; do sleep 0.05; done
    ;;
  empty-clean) exit 0 ;;
  nonzero) exit 7 ;;
  external-healthy) printf 'watcher: healthy pid=1 (beacon 0s)\n' ;;
  send-message-throw) printf 'signal: synthetic wake\n' ;;
  *) exit 0 ;;
esac
SH
    chmod +x "$repo/bin/fm-lock.sh" "$repo/bin/fm-watch-arm.sh"
    if [ "$case_name" = spawn-enoent ]; then
      out=$(PATH="$empty_path" PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" \
        STATUS_HARNESS="$repo/status-harness.mjs" FM_ARM_LOG="$arm_log" FM_ATTENTION_CASE="$case_name" \
        "$node_bin" --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(pathToFileURL(process.env.STATUS_HARNESS).href);
const harness = makeStatusHarness();
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(harness.pi);
await harness.handlers.get("session_start")?.({ type: "session_start" }, harness.ctx);
await harness.tool().execute("status-attention", {}, undefined, undefined, {});
for (let i = 0; i < 100 && harness.writes.at(-1)?.[1] !== "attention"; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "attention"]);
EOF
      )
    else
      out=$(PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" \
        STATUS_HARNESS="$repo/status-harness.mjs" FM_ARM_LOG="$arm_log" FM_ATTENTION_CASE="$case_name" \
        node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(pathToFileURL(process.env.STATUS_HARNESS).href);
const harness = makeStatusHarness();
let otherOwner = null;
if (process.env.FM_ATTENTION_CASE === "live-other-owner") {
  const { spawn } = await import("node:child_process");
  otherOwner = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
  await new Promise((resolve, reject) => {
    otherOwner.once("spawn", resolve);
    otherOwner.once("error", reject);
  });
  writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${otherOwner.pid}\n`);
} else if (process.env.FM_ATTENTION_CASE !== "recovery-no-ownership") {
  writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
}
if (process.env.FM_ATTENTION_CASE === "send-message-throw") {
  harness.pi.sendMessage = () => {
    throw new Error("synthetic sendMessage failure");
  };
}
harness.pi.sendUserMessage = () => {
  throw new Error("watcher wake was delivered as a user-role message");
};
try {
  const mod = await import(pathToFileURL(process.env.PLUGIN).href);
  mod.default(harness.pi);
  await harness.handlers.get("session_start")?.({ type: "session_start" }, harness.ctx);
  await harness.tool().execute("status-attention", {}, undefined, undefined, {});
  if (["live-other-owner", "recovery-no-ownership"].includes(process.env.FM_ATTENTION_CASE)) {
    assert.equal(existsSync(process.env.FM_ARM_LOG), false, "ownership refusal spawned an arm child");
  }
  const coordinator = [...globalThis.__firstmatePiWatchCoordinators.values()][0];
  const record = coordinator?.current;
  if (process.env.FM_ATTENTION_CASE === "child-error") {
    assert.ok(record, "child-error arm record missing");
    record.child.emit("error", new Error("synthetic child error"));
    if (record.child.pid) process.kill(-record.child.pid, "SIGTERM");
  } else if (process.env.FM_ATTENTION_CASE === "unexpected-signal") {
    assert.ok(record, "unexpected-signal arm record missing");
    if (record.child.pid) process.kill(-record.child.pid, "SIGKILL");
  }
  for (let i = 0; i < 100 && harness.writes.at(-1)?.[1] !== "attention"; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "attention"]);
  if (process.env.FM_ATTENTION_CASE === "unexpected-signal") {
    assert.equal(harness.messages[0]?.message.details.signal, "SIGKILL");
  }
  if (process.env.FM_ATTENTION_CASE === "send-message-throw") {
    assert.equal(harness.writes.some(([, value]) => value === "handling wake"), false);
  }
} finally {
  if (otherOwner) {
    otherOwner.kill("SIGTERM");
    await new Promise((resolve) => otherOwner.once("close", resolve));
  }
}
EOF
      )
    fi
    status=$?
    expect_code 0 "$status" "Pi $case_name outcome must publish attention"
    [ -z "$out" ] || fail "Pi $case_name attention-status test printed output: $out"
  done
  pass "Pi ownership, startup, child, external-owner, and delivery failures publish attention"
}

test_pi_status_intentional_stop_offline() {
  local repo plugin out status
  repo="$TMP_ROOT/pi-status-intentional-stop-root"
  mkdir -p "$repo/bin" "$repo/config" "$repo/state"
  install_pi_watch_extension_fixture "$repo"
  install_pi_status_harness "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" STATUS_HARNESS="$repo/status-harness.mjs" \
    node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(pathToFileURL(process.env.STATUS_HARNESS).href);
const harness = makeStatusHarness();
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(harness.pi);
await harness.handlers.get("session_start")?.({ type: "session_start" }, harness.ctx);
await harness.tool().execute("status-intentional-stop", {}, undefined, undefined, {});
const coordinator = [...globalThis.__firstmatePiWatchCoordinators.values()][0];
const record = coordinator.current;
assert.ok(record, "intentional-stop arm record missing");
await mod.stopArm(coordinator, "manual-stop", "offline");
assert.equal(record.intentionalStopReason, "manual-stop");
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "offline"]);
assert.equal(harness.writes.some(([, value]) => value === "attention"), false);
assert.equal(harness.messages.length, 0);
await harness.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, harness.ctx);
EOF
  )
  status=$?
  expect_code 0 "$status" "A normal intentional Pi watcher stop must settle offline without attention or wake"
  [ -z "$out" ] || fail "Pi intentional-stop status test printed output: $out"
  pass "A normal intentional Pi watcher stop settles offline without attention or wake"
}

test_pi_status_reload_and_quit_clear() {
  local repo plugin out status
  repo="$TMP_ROOT/pi-status-reload-quit-root"
  mkdir -p "$repo/bin" "$repo/config" "$repo/state"
  install_pi_watch_extension_fixture "$repo"
  install_pi_status_harness "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'sleep 0.05; exit 0' TERM
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" STATUS_HARNESS="$repo/status-harness.mjs" \
    node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(pathToFileURL(process.env.STATUS_HARNESS).href);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const url = pathToFileURL(process.env.PLUGIN).href;

const oldHarness = makeStatusHarness();
const oldModule = await import(`${url}?status-client=old`);
oldModule.default(oldHarness.pi);
await oldHarness.handlers.get("session_start")?.({ type: "session_start" }, oldHarness.ctx);
await oldHarness.tool().execute("status-before-reload", {}, undefined, undefined, {});
assert.deepEqual(oldHarness.writes.at(-1), ["firstmate-pi-watcher", "watching"]);
const reload = Promise.resolve(
  oldHarness.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "reload" }, oldHarness.ctx),
);
assert.deepEqual(oldHarness.writes.at(-1), ["firstmate-pi-watcher", undefined]);
await reload;
const oldWritesAfterClear = oldHarness.writes.length;
await new Promise((resolve) => setTimeout(resolve, 80));
assert.equal(oldHarness.writes.length, oldWritesAfterClear);

const newHarness = makeStatusHarness();
const newModule = await import(`${url}?status-client=new`);
newModule.default(newHarness.pi);
await newHarness.handlers.get("session_start")?.({ type: "session_start" }, newHarness.ctx);
assert.deepEqual(newHarness.writes, [["firstmate-pi-watcher", "offline"]]);
await newHarness.tool().execute("status-before-quit", {}, undefined, undefined, {});
assert.deepEqual(newHarness.writes.at(-1), ["firstmate-pi-watcher", "watching"]);
const quit = Promise.resolve(
  newHarness.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, newHarness.ctx),
);
assert.deepEqual(newHarness.writes.at(-1), ["firstmate-pi-watcher", undefined]);
await quit;
const newWritesAfterClear = newHarness.writes.length;
await new Promise((resolve) => setTimeout(resolve, 80));
assert.equal(newHarness.writes.length, newWritesAfterClear);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi reload and quit must clear before cleanup and replacement must begin offline"
  [ -z "$out" ] || fail "Pi reload-and-quit status test printed output: $out"
  pass "Pi reload and quit clear before cleanup and replacement begins offline"
}

test_pi_status_reload_overlap_preserves_replacement_ownership() {
  local repo plugin arm_log arm_ready term_seen term_release out status
  repo="$TMP_ROOT/pi-status-reload-overlap-root"
  arm_log="$TMP_ROOT/pi-status-reload-overlap-arm.log"
  arm_ready="$TMP_ROOT/pi-status-reload-overlap-arm-ready"
  term_seen="$TMP_ROOT/pi-status-reload-overlap-term-seen"
  term_release="$TMP_ROOT/pi-status-reload-overlap-term-release"
  mkdir -p "$repo/bin" "$repo/config" "$repo/state"
  install_pi_watch_extension_fixture "$repo"
  install_pi_status_harness "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "${FM_ARM_LOG:?}"
arm_number=$(wc -l < "$FM_ARM_LOG" | tr -d ' ')
if [ "$arm_number" -eq 1 ]; then
  trap ': > "$FM_TERM_SEEN"; while [ ! -f "$FM_TERM_RELEASE" ]; do sleep 0.01; done; exit 0' TERM
  : > "$FM_ARM_READY"
else
  trap 'exit 0' TERM
fi
while :; do sleep 0.01; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" STATUS_HARNESS="$repo/status-harness.mjs" \
    FM_ARM_LOG="$arm_log" FM_ARM_READY="$arm_ready" FM_TERM_SEEN="$term_seen" FM_TERM_RELEASE="$term_release" \
    FM_PI_WATCH_STOP_GRACE_MS=5000 node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(pathToFileURL(process.env.STATUS_HARNESS).href);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const url = pathToFileURL(process.env.PLUGIN).href;
const initialExitListeners = process.listenerCount("exit");

const oldHarness = makeStatusHarness();
const oldModule = await import(`${url}?status-overlap=old`);
oldModule.default(oldHarness.pi);
await oldHarness.handlers.get("session_start")?.({ type: "session_start" }, oldHarness.ctx);
await oldHarness.tool().execute("status-overlap-old-arm", {}, undefined, undefined, {});
const coordinator = [...globalThis.__firstmatePiWatchCoordinators.values()][0];
const oldRecord = coordinator.current;
assert.ok(oldRecord, "reload-overlap old arm record missing");
assert.equal(process.listenerCount("exit"), initialExitListeners + 1);
for (let i = 0; i < 200 && !existsSync(process.env.FM_ARM_READY); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
assert.equal(existsSync(process.env.FM_ARM_READY), true, "old arm did not become ready");

const oldShutdown = Promise.resolve(
  oldHarness.handlers.get("session_shutdown")?.(
    { type: "session_shutdown", reason: "reload" },
    oldHarness.ctx,
  ),
);
assert.deepEqual(oldHarness.writes.at(-1), ["firstmate-pi-watcher", undefined]);
for (let i = 0; i < 200 && !existsSync(process.env.FM_TERM_SEEN); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
assert.equal(existsSync(process.env.FM_TERM_SEEN), true, "old arm TERM cleanup did not pause");

const newHarness = makeStatusHarness();
const newModule = await import(`${url}?status-overlap=new`);
newModule.default(newHarness.pi);
await newHarness.handlers.get("session_start")?.({ type: "session_start" }, newHarness.ctx);
assert.deepEqual(newHarness.writes, [["firstmate-pi-watcher", "offline"]]);
assert.equal(process.listenerCount("exit"), initialExitListeners + 1);

const replacementArm = newHarness.tool().execute(
  "status-overlap-replacement-arm",
  {},
  undefined,
  undefined,
  {},
);
await new Promise((resolve) => setTimeout(resolve, 30));
assert.equal(readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length, 1);
assert.deepEqual(newHarness.writes.at(-1), ["firstmate-pi-watcher", "offline"]);

writeFileSync(process.env.FM_TERM_RELEASE, "release\n");
const [, result] = await Promise.all([oldShutdown, replacementArm]);
assert.equal(result.details?.ok, true);
assert.match(result.content?.[0]?.text ?? "", /started Pi extension arm child/);
assert.ok(coordinator.current, "reload-overlap replacement arm was cleared by stale shutdown");
assert.notEqual(coordinator.current, oldRecord);
assert.equal(coordinator.state, "running");
assert.deepEqual(newHarness.writes.at(-1), ["firstmate-pi-watcher", "watching"]);
assert.deepEqual(oldHarness.writes.at(-1), ["firstmate-pi-watcher", undefined]);
assert.equal(oldHarness.messages.length, 0);
assert.equal(newHarness.messages.length, 0);
assert.ok(coordinator.exitListener, "reload-overlap stale shutdown removed the active exit listener");
assert.equal(process.listenerCount("exit"), initialExitListeners + 1);

await newHarness.handlers.get("session_shutdown")?.(
  { type: "session_shutdown", reason: "quit" },
  newHarness.ctx,
);
assert.equal(coordinator.current, null);
assert.equal(coordinator.exitListener, undefined);
assert.equal(process.listenerCount("exit"), initialExitListeners);
assert.deepEqual(newHarness.writes.at(-1), ["firstmate-pi-watcher", undefined]);
EOF
  )
  status=$?
  expect_code 0 "$status" "An overlapping reload must serialize cleanup before replacement arm ownership"
  [ -z "$out" ] || fail "Pi reload-overlap status test printed output: $out"
  pass "Pi overlapping reload preserves replacement arm, status, and exit-listener ownership"
}

test_pi_status_stale_generation_cannot_overwrite() {
  local repo plugin out status
  repo="$TMP_ROOT/pi-status-stale-generation-root"
  mkdir -p "$repo/bin" "$repo/config" "$repo/state"
  install_pi_watch_extension_fixture "$repo"
  install_pi_status_harness "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" STATUS_HARNESS="$repo/status-harness.mjs" \
    node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(pathToFileURL(process.env.STATUS_HARNESS).href);
const harness = makeStatusHarness();
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(harness.pi);
await harness.handlers.get("session_start")?.({ type: "session_start" }, harness.ctx);
await harness.tool().execute("status-old-generation", {}, undefined, undefined, {});
const coordinator = [...globalThis.__firstmatePiWatchCoordinators.values()][0];
const old = coordinator.current;
assert.ok(old, "old status generation missing");
coordinator.current = null;
coordinator.state = "idle";
await harness.tool().execute("status-replacement-generation", {}, undefined, undefined, {});
const replacement = coordinator.current;
assert.ok(replacement && replacement !== old, "replacement status generation missing");

const assertStalePreserves = async (expected) => {
  const writes = harness.writes.length;
  const messages = harness.messages.length;
  old.child.emit("error", new Error(`stale over ${String(expected)}`));
  old.child.emit("close", 7, null);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(harness.writes.length, writes);
  assert.equal(harness.messages.length, messages);
  assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", expected]);
};

await assertStalePreserves("watching");
replacement.child.stdout.emit("data", Buffer.from("signal: synthetic current wake\n"));
replacement.child.emit("close", 0, null);
await new Promise((resolve) => setTimeout(resolve, 20));
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "handling wake"]);
await assertStalePreserves("handling wake");
if (replacement.child.pid) process.kill(-replacement.child.pid, "SIGTERM");

await harness.tool().execute("status-attention-generation", {}, undefined, undefined, {});
const attentionRecord = coordinator.current;
assert.ok(attentionRecord, "attention status generation missing");
attentionRecord.child.emit("error", new Error("synthetic current failure"));
await new Promise((resolve) => setTimeout(resolve, 20));
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "attention"]);
await assertStalePreserves("attention");
if (attentionRecord.child.pid) process.kill(-attentionRecord.child.pid, "SIGTERM");

const shutdown = Promise.resolve(
  harness.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, harness.ctx),
);
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", undefined]);
await assertStalePreserves(undefined);
await shutdown;
if (old.child.pid) process.kill(-old.child.pid, "SIGKILL");
EOF
  )
  status=$?
  expect_code 0 "$status" "A stale Pi watcher generation must not overwrite current or cleared status"
  [ -z "$out" ] || fail "Pi stale-generation status test printed output: $out"
  pass "A stale Pi watcher generation cannot overwrite watching, handling wake, attention, or clear"
}

test_pi_status_cancelled_start_stays_cleared() {
  local repo plugin lock_started lock_release arm_log out status
  repo="$TMP_ROOT/pi-status-cancelled-start-root"
  lock_started="$TMP_ROOT/pi-status-cancelled-start-lock-started"
  lock_release="$TMP_ROOT/pi-status-cancelled-start-lock-release"
  arm_log="$TMP_ROOT/pi-status-cancelled-start-arm.log"
  mkdir -p "$repo/bin" "$repo/config" "$repo/state"
  install_pi_watch_extension_fixture "$repo"
  install_pi_status_harness "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_LOCK_STARTED:?}"
while [ ! -f "${FM_LOCK_RELEASE:?}" ]; do sleep 0.01; done
printf '%s\n' "$PPID" > "$FM_HOME/state/.lock"
SH
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-lock.sh" "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$repo" FM_ROOT_OVERRIDE="$repo" STATUS_HARNESS="$repo/status-harness.mjs" \
    FM_LOCK_STARTED="$lock_started" FM_LOCK_RELEASE="$lock_release" FM_ARM_LOG="$arm_log" \
    node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(pathToFileURL(process.env.STATUS_HARNESS).href);
const harness = makeStatusHarness();
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(harness.pi);
await harness.handlers.get("session_start")?.({ type: "session_start" }, harness.ctx);
assert.deepEqual(harness.writes, [["firstmate-pi-watcher", "offline"]]);
const start = harness.tool().execute("status-pending-start", {}, undefined, undefined, {});
for (let i = 0; i < 100 && !existsSync(process.env.FM_LOCK_STARTED); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
assert.equal(existsSync(process.env.FM_LOCK_STARTED), true);
const shutdown = Promise.resolve(
  harness.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, harness.ctx),
);
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", undefined]);
const writesAfterClear = harness.writes.length;
writeFileSync(process.env.FM_LOCK_RELEASE, "release\n");
const [result] = await Promise.all([start, shutdown]);
assert.equal(result.details?.ok, false);
assert.match(result.content?.[0]?.text ?? "", /session shut down/);
await new Promise((resolve) => setTimeout(resolve, 80));
assert.equal(harness.writes.length, writesAfterClear);
assert.equal(existsSync(process.env.FM_ARM_LOG), false);
assert.equal(harness.messages.length, 0);
EOF
  )
  status=$?
  expect_code 0 "$status" "A cancelled pending Pi watcher start must clear before release and stay cleared"
  [ -z "$out" ] || fail "Pi cancelled-start status test printed output: $out"
  pass "A cancelled pending Pi watcher start clears before release and never rewrites or spawns"
}

test_pi_status_absent_in_task_worktree() {
  local base worktree plugin out status
  base="$TMP_ROOT/pi-status-absent-base"
  worktree="$TMP_ROOT/pi-status-absent-worktree"
  fm_git_worktree "$base" "$worktree" fm/pi-status-absent
  install_pi_watch_extension_fixture "$worktree"
  plugin="$worktree/.pi/extensions/fm-primary-pi-watch.ts"

  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE PLUGIN="$plugin" node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

let registrations = 0;
const statusWrites = [];
const pi = {
  on() { registrations += 1; },
  registerCommand() { registrations += 1; },
  registerTool() { registrations += 1; },
  sendMessage() {},
};
const ctx = {
  ui: {
    setStatus(key, text) { statusWrites.push([key, text]); },
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
assert.equal(registrations, 0);
assert.deepEqual(statusWrites, []);
void ctx;
EOF
  )
  status=$?
  expect_code 0 "$status" "ordinary task worktrees must leave Pi watcher status absent"
  [ -z "$out" ] || fail "Pi task-worktree status-absence test printed output: $out"
  pass "Pi watcher status stays absent in an ordinary linked task worktree"
}

test_pi_status_static_non_goals() {
  local text timer_lines timer_block forbidden
  text=$(cat "$EXT")
  assert_contains "$text" '"firstmate-pi-watcher"' "Pi watcher status key drifted"
  assert_contains "$text" 'customType: "firstmate-watcher-wake"' "Pi watcher custom wake type drifted"
  assert_not_contains "$text" 'sendUserMessage' "Pi watcher still sends a synthetic user message"
  for forbidden in 'setInterval(' 'setWidget(' 'setFooter(' 'gh pr' 'backlog.md' 'fm-pr-' 'tmux job' 'stall watchdog'; do
    assert_not_contains "$text" "$forbidden" "Pi watcher status introduced forbidden surface: $forbidden"
  done
  timer_lines=$(grep -n 'setTimeout(' "$EXT" || true)
  [ "$(printf '%s\n' "$timer_lines" | grep -c .)" -eq 1 ] \
    || fail "Pi watcher must keep exactly one bounded cleanup timer source"
  assert_contains "$timer_lines" 'setTimeout(check, Math.min(10, remaining))' \
    "Pi watcher contains a timer outside bounded process-group cleanup"
  timer_block=$(sed -n '/function stopsWithin/,/^}/p' "$EXT")
  assert_contains "$timer_block" 'const deadline = Date.now() + milliseconds' \
    "Pi watcher cleanup timer lost its absolute bound"
  assert_contains "$timer_block" 'if (remaining <= 0)' \
    "Pi watcher cleanup timer lost its deadline exit"
  assert_not_contains "$timer_block" 'publishStatus' "Pi watcher cleanup timer refreshes status"
  assert_not_contains "$timer_block" 'writeClientStatus' "Pi watcher cleanup timer writes client status"
  assert_not_contains "$timer_block" 'visibleStatus' "Pi watcher cleanup timer reads visible status"
  pass "Pi watcher status source stays event-driven and excludes product UI scope"
}

installed_pi_package_dir() {
  local candidate pi_bin pi_target
  if [ -n "${FM_PI_PACKAGE_DIR:-}" ]; then
    printf '%s\n' "$FM_PI_PACKAGE_DIR"
    return
  fi
  candidate="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"
  if [ -f "$candidate/dist/core/agent-session.js" ]; then
    printf '%s\n' "$candidate"
    return
  fi
  pi_bin=$(command -v pi 2>/dev/null || true)
  [ -L "$pi_bin" ] || return
  pi_target=$(readlink "$pi_bin")
  case "$pi_target" in
    /*) ;;
    *) pi_target="$(cd "$(dirname "$pi_bin")" && cd "$(dirname "$pi_target")" && pwd -P)/$(basename "$pi_target")" ;;
  esac
  candidate=$(cd "$(dirname "$pi_target")/.." 2>/dev/null && pwd -P)
  [ -f "$candidate/dist/core/agent-session.js" ] && printf '%s\n' "$candidate"
}

test_tracked_extension_present_and_self_hashing() {
  local text expected_config_source extension_count
  expected_config_source="config_dir=\\\"\${FM_CONFIG_OVERRIDE:-\$FM_HOME/config}\\\""
  assert_present "$EXT" "tracked Pi primary watcher extension is missing"
  extension_count=$(find "$ROOT/.pi/extensions" -maxdepth 1 -type f -name '*.ts' | wc -l | tr -d ' ')
  [ "$extension_count" -eq 1 ] || fail "expected one tracked Pi extension, found $extension_count"
  text=$(cat "$EXT")
  assert_contains "$text" "fm_watch_arm_pi" "tracked extension missing tool name"
  assert_contains "$text" "fm-watch-arm-pi" "tracked extension missing command name"
  assert_contains "$text" "fm-watch-arm.sh" "tracked extension missing watcher arm"
  assert_contains "$text" "pi.sendMessage" "tracked extension missing Pi custom wake API"
  assert_contains "$text" 'customType: "firstmate-watcher-wake"' "tracked extension missing stable watcher wake custom type"
  assert_contains "$text" 'display: true' "tracked extension missing persistent custom wake display"
  assert_contains "$text" 'deliverAs: "followUp"' "tracked extension missing followUp delivery"
  assert_contains "$text" 'triggerTurn: true' "tracked extension missing idle turn trigger"
  assert_not_contains "$text" "sendUserMessage" "tracked extension still manufactures captain-authored user messages"
  assert_contains "$text" "detached: true" "tracked extension does not own a detached arm process group"
  assert_contains "$text" "MAX_CAPTURE_BYTES" "tracked extension does not bound watcher output capture"
  assert_contains "$text" ".pi-watch-extension-loaded" "tracked extension missing loaded marker"
  assert_contains "$text" 'createHash("sha256").update(readFileSync(extensionFile)).digest("hex")' "tracked extension does not self-hash its own content for extensionVersion"
  assert_contains "$text" 'fileURLToPath(import.meta.url)' "tracked extension does not self-locate via import.meta.url"
  assert_contains "$text" 'type LockOwnership = "owned" | "missing" | "other"' "tracked extension does not distinguish missing lock from another owner"
  assert_contains "$text" "readFileSync(\`\${state}/.lock\`" "tracked extension does not read the effective session lock"
  assert_contains "$text" 'return pidAlive(lockPid) ? "other" : "missing"' "tracked extension does not allow a pre-lock load marker"
  assert_contains "$text" 'if (lockOwnership() !== "owned") await claimSessionLock()' "tracked extension does not delegate every non-owned state to the home lock protocol"
  assert_contains "$text" 'if (lockOwnership() !== "owned") {' "tracked extension does not re-check lock ownership after recovery"
  assert_contains "$text" 'signal: NodeJS.Signals | null' "tracked extension does not retain child close signals"
  assert_contains "$text" "writeFileSync(marker, \`\${extensionVersion}\\n\${process.pid}\\n\`)" "tracked extension does not write the content version and process marker"
  assert_contains "$text" "const config = process.env.FM_CONFIG_OVERRIDE" "tracked extension missing effective config resolution"
  assert_contains "$text" "FM_CONFIG_OVERRIDE: config" "tracked extension does not pass the effective config to the watcher arm"
  assert_contains "$text" "FM_WATCH_ARM_SCRIPT: armScript" "tracked extension does not pass the effective watcher arm script"
  assert_contains "$text" "$expected_config_source" "tracked extension does not source the effective x-mode config"
  assert_contains "$text" "exec \\\"\$FM_WATCH_ARM_SCRIPT\\\" --restart" "tracked extension does not restart into a Pi-owned watcher child"
  assert_contains "$text" 'label: "Arm firstmate watcher"' "tracked extension tool is missing its human-readable label"
  assert_contains "$text" 'parameters: Type.Object({})' "tracked extension tool is not using Pi's canonical TypeBox schema"
  assert_contains "$text" 'content: [{ type: "text", text: result.message }]' "tracked extension tool is missing Pi text content"
  assert_contains "$text" 'details: result' "tracked extension tool is missing structured result details"
  assert_contains "$text" 'ctx.ui.notify' "tracked extension command does not notify through Pi's UI"
  assert_contains "$text" 'process.once("exit", cleanupOnProcessExit)' "tracked extension lacks clean-process-exit cleanup"
  assert_contains "$text" 'if (!supervisingHome()) return' "tracked extension does not gate setup on a supervising home"
  assert_contains "$text" '.fm-secondmate-home' "tracked extension does not recognize persistent secondmate homes"
  assert_contains "$text" 'rev-parse", "--git-dir' "tracked extension does not distinguish linked task worktrees"
  assert_contains "$text" 'pi.on("tool_call"' "tracked watcher extension does not carry the PreToolUse seatbelt"
  assert_not_contains "$text" "[ -f config/x-mode.env ]" "tracked extension kept a repo-relative x-mode config path"
  pass "Pi primary watcher extension is tracked, self-hashing, and self-locating"
}

test_pi_extension_supervises_only_primary_or_secondmate_homes() {
  local base worktree home plugin lock_log arm_log out status
  base="$TMP_ROOT/pi-scope-base"
  worktree="$TMP_ROOT/pi-scope-worktree"
  home="$TMP_ROOT/pi-scope-home"
  lock_log="$TMP_ROOT/pi-scope-lock.log"
  arm_log="$TMP_ROOT/pi-scope-arm.log"
  fm_git_worktree "$base" "$worktree" fm/pi-scope
  install_pi_watch_extension_fixture "$worktree"
  plugin="$worktree/.pi/extensions/fm-primary-pi-watch.ts"
  mkdir -p "$worktree/bin" "$home/state" "$home/config"
  printf 'secondmate-home\n' > "$home/.fm-secondmate-home"
  printf '999999\n' > "$home/state/.lock"
  cat > "$worktree/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf 'lock\n' >> "${FM_LOCK_LOG:?}"
SH
  cat > "$worktree/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$worktree/bin/fm-lock.sh" "$worktree/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$worktree" FM_LOCK_LOG="$lock_log" FM_ARM_LOG="$arm_log" node --input-type=module 2>&1 <<'EOF'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

let registrations = 0;
const pi = {
  on() { registrations += 1; },
  registerCommand() { registrations += 1; },
  registerTool() { registrations += 1; },
  sendMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (registrations !== 0) throw new Error(`linked worktree registered ${registrations} watcher callbacks`);
if (existsSync(`${process.env.FM_HOME}/state/.pi-watch-extension-loaded`)) throw new Error("linked worktree wrote the loaded marker");
if (existsSync(process.env.FM_LOCK_LOG)) throw new Error("linked worktree attempted lock recovery");
if (existsSync(process.env.FM_ARM_LOG)) throw new Error("linked worktree armed the watcher");
EOF
)
  status=$?
  expect_code 0 "$status" "ordinary linked task worktrees must keep the Pi watcher extension inert"
  [ -z "$out" ] || fail "Pi linked-worktree scope test printed output: $out"

  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE PLUGIN="$plugin" WORKTREE="$worktree" node --input-type=module 2>&1 <<'EOF'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

let registrations = 0;
const pi = {
  on() { registrations += 1; },
  registerCommand() { registrations += 1; },
  registerTool() { registrations += 1; },
  sendMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (registrations !== 0) throw new Error(`default-env linked worktree registered ${registrations} watcher callbacks`);
if (existsSync(`${process.env.WORKTREE}/state/.pi-watch-extension-loaded`)) {
  throw new Error("default-env linked worktree wrote the loaded marker");
}
EOF
)
  status=$?
  expect_code 0 "$status" "default-env ordinary linked task worktrees must keep the Pi watcher extension inert"
  [ -z "$out" ] || fail "Pi default-env linked-worktree scope test printed output: $out"

  mkdir -p "$worktree/state" "$worktree/config"
  out=$(PLUGIN="$plugin" FM_HOME="$worktree" FM_ROOT_OVERRIDE="$worktree" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let command = null;
let tool = null;
const pi = {
  on() {},
  registerCommand(name) {
    if (name === "fm-watch-arm-pi") command = name;
  },
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate.name;
  },
  sendMessage() {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (command !== "fm-watch-arm-pi") throw new Error("effective linked primary did not register the watcher command");
if (tool !== "fm_watch_arm_pi") throw new Error("effective linked primary did not register the watcher tool");
const marker = `${process.env.FM_HOME}/state/.pi-watch-extension-loaded`;
if (!existsSync(marker)) throw new Error("effective linked primary did not write the loaded marker");
const [version, pid] = readFileSync(marker, "utf8").trim().split("\n");
if (!version.startsWith("sha256:")) throw new Error(`loaded marker did not contain the candidate hash: ${version}`);
if (pid !== String(process.pid)) throw new Error(`loaded marker pid ${pid} did not match current Pi-shaped process ${process.pid}`);
EOF
)
  status=$?
  expect_code 0 "$status" "the effective primary home must load the watcher even when Treehouse represents it as a linked worktree"
  [ -z "$out" ] || fail "Pi effective linked-primary test printed output: $out"

  mkdir -p "$base/bin" "$base/state" "$base/config"
  : > "$base/AGENTS.md"
  printf '999999\n' > "$base/state/.lock"
  cat > "$base/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf 'lock\n' >> "${FM_LOCK_LOG:?}"
SH
  cat > "$base/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$base/bin/fm-lock.sh" "$base/bin/fm-watch-arm.sh"
  rm -f "$lock_log" "$arm_log"
  out=$(PLUGIN="$plugin" FM_HOME="$base" FM_ROOT_OVERRIDE="$base" FM_LOCK_LOG="$lock_log" FM_ARM_LOG="$arm_log" node --input-type=module 2>&1 <<'EOF'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

let registrations = 0;
const pi = {
  on() { registrations += 1; },
  registerCommand() { registrations += 1; },
  registerTool() { registrations += 1; },
  sendMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (registrations !== 0) throw new Error(`override escape registered ${registrations} watcher callbacks`);
if (existsSync(`${process.env.FM_HOME}/state/.pi-watch-extension-loaded`)) throw new Error("override escape wrote the loaded marker");
if (existsSync(process.env.FM_LOCK_LOG)) throw new Error("override escape attempted lock recovery");
if (existsSync(process.env.FM_ARM_LOG)) throw new Error("override escape armed the watcher");
EOF
)
  status=$?
  expect_code 0 "$status" "a primary FM_ROOT_OVERRIDE must not let a linked-worktree extension supervise"
  [ -z "$out" ] || fail "Pi FM_ROOT_OVERRIDE scope test printed output: $out"

  printf 'secondmate-scope\n' > "$worktree/.fm-secondmate-home"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$worktree" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("marked secondmate did not register the watcher tool");
if (!existsSync(`${process.env.FM_HOME}/state/.pi-watch-extension-loaded`)) throw new Error("marked secondmate did not write the loaded marker");
EOF
)
  status=$?
  expect_code 0 "$status" "marked persistent secondmate homes must retain Pi watcher supervision"
  [ -z "$out" ] || fail "Pi secondmate scope test printed output: $out"
  pass "Pi watcher scope admits primary and marked secondmate homes while linked task worktrees stay inert"
}

test_pi_live_lab_cleanup_is_owned() {
  local script helper text helper_text
  script="$ROOT/tests/fm-pi-primary-live-e2e.test.sh"
  helper="$ROOT/tests/fm-pi-detached-launch-helper.sh"
  text=$(cat "$script")
  helper_text=$(cat "$helper")
  # shellcheck disable=SC2016  # These are literal source-code assertions.
  assert_contains "$text" 'mktemp -d "$ROOT/.pi-live-e2e.XXXXXX"' "live Pi test does not allocate a fresh worktree-local lab"
  # shellcheck disable=SC2016
  assert_contains "$text" 'LAB_SENTINEL="$LAB/.fm-pi-live-e2e-owned"' "live Pi test does not mark ownership of its lab"
  # shellcheck disable=SC2016
  assert_contains "$text" '[ -f "$LAB_SENTINEL" ]' "live Pi cleanup does not require its ownership sentinel"
  assert_not_contains "$text" 'FM_PI_LIVE_LAB' "live Pi test still accepts a caller-selected cleanup path"
  assert_contains "$text" 'respawn-pane -k' "live Pi test does not replace the old Pi directly at the pane boundary"
  assert_contains "$text" 'build_pi_launch_command' "live Pi test does not centralize quoted candidate launch construction"
  assert_contains "$text" 'LAUNCH_HELPER=' "live Pi candidate launch does not route through the argv-preserving helper"
  assert_contains "$helper_text" 'exec env' "live Pi candidate launch retains an avoidable wrapper process"
  assert_contains "$text" 'registration-probe.ts' "live Pi test does not prove tool and command registration after detached restart"
  assert_present "$helper" "detached Pi launch helper is missing"
  pass "Pi live regression cleanup is confined to its fresh owned lab"
}

test_pi_detached_launch_helper_preserves_exact_argv() {
  local helper case_dir fake_pi log pi_dir home watch probe prompt out status helper_pid launched_pid
  helper="$ROOT/tests/fm-pi-detached-launch-helper.sh"
  case_dir="$TMP_ROOT/pi detached launch"
  fake_pi="$case_dir/fake pi"
  log="$case_dir/launch.log"
  pi_dir="$case_dir/pi agent"
  home="$case_dir/firstmate home"
  watch="$home/.pi/extensions/fm-primary-pi-watch.ts"
  probe="$home/state/registration probe.ts"
  prompt="Reply exactly: quote ' and spaces"
  mkdir -p "$case_dir" "$pi_dir" "$(dirname "$watch")" "$(dirname "$probe")"
  cat > "$fake_pi" <<'SH'
#!/usr/bin/env bash
{
  printf 'pid=%s\n' "$$"
  printf 'pi_dir=%s\n' "${PI_CODING_AGENT_DIR:-}"
  printf 'fm_home=%s\n' "${FM_HOME:-}"
  printf 'fm_root=%s\n' "${FM_ROOT_OVERRIDE:-}"
  printf 'probe_env=%s\n' "${FM_PI_REGISTRATION_PROBE:-}"
  printf 'argc=%s\n' "$#"
  i=0
  for arg in "$@"; do
    printf 'arg_%s=%s\n' "$i" "$arg"
    i=$((i + 1))
  done
} > "${FM_PI_LAUNCH_LOG:?}"
SH
  chmod +x "$fake_pi"

  FM_PI_LAUNCH_LOG="$log" "$helper" "$fake_pi" "$pi_dir" "$home" "$watch" "$probe" "$prompt" &
  helper_pid=$!
  wait "$helper_pid"
  status=$?
  expect_code 0 "$status" "detached Pi launch helper must exec the exact candidate argv"
  launched_pid=$(sed -n 's/^pid=//p' "$log")
  [ "$launched_pid" = "$helper_pid" ] || fail "launch helper left a wrapper pid $helper_pid around Pi pid $launched_pid"
  assert_grep "pi_dir=$pi_dir" "$log" "launch helper split the Pi agent directory"
  assert_grep "fm_home=$home" "$log" "launch helper split the Firstmate home"
  assert_grep "fm_root=$home" "$log" "launch helper did not root the candidate at its effective home"
  assert_grep "probe_env=$home/state/registrations.txt" "$log" "launch helper did not set the registration evidence path"
  assert_grep 'argc=9' "$log" "launch helper passed the wrong argument count"
  assert_grep 'arg_0=--approve' "$log" "launch helper omitted one-run project approval"
  assert_grep 'arg_1=--offline' "$log" "launch helper changed offline startup ordering"
  assert_grep 'arg_2=--no-session' "$log" "launch helper changed ephemeral-session startup ordering"
  assert_grep 'arg_3=--verbose' "$log" "launch helper omitted verbose resource evidence"
  assert_grep 'arg_4=-e' "$log" "launch helper omitted the watcher extension flag"
  assert_grep "arg_5=$watch" "$log" "launch helper split the watcher extension path"
  assert_grep 'arg_6=-e' "$log" "launch helper omitted the registration probe flag"
  assert_grep "arg_7=$probe" "$log" "launch helper split the registration probe path"
  assert_grep "arg_8=$prompt" "$log" "launch helper split or evaluated the initial prompt"
  [ -z "${out:-}" ] || fail "detached launch helper printed unexpected output: $out"
  pass "Pi detached launch helper preserves exact quoted argv and replaces itself with one Pi process"
}

test_spawn_template_mentions_pi_watch_placeholder() {
  local text
  text=$(cat "$ROOT/bin/fm-spawn.sh")
  assert_contains "$text" "--approve -e __PIWATCH__" "Pi secondmate launch template does not approve the home while loading the tracked watcher extension"
  assert_contains "$text" "\$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts" "fm-spawn does not point the Pi secondmate watch placeholder at the tracked extension"
  assert_not_contains "$text" "state/fm-primary-pi-watch.ts" "fm-spawn must never launch a generated Pi watcher copy"
  assert_not_contains "$text" "fm-pi-watch-extension.sh" "fm-spawn should no longer generate the Pi watch extension before launch"
  assert_contains "$text" "__PIWATCH__" "fm-spawn does not replace the Pi watch extension placeholder"
  pass "Pi secondmate launch wiring includes the tracked watcher extension"
}

test_pi_extension_reports_external_healthy_watcher() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-external-healthy-root"
  home="$TMP_ROOT/pi-external-healthy-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let handler = null;
let notification = "";
let prompt = "";
const pi = {
  on() {},
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") handler = options.handler;
  },
  registerTool() {},
  sendMessage: async (message) => {
    prompt = message.content;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!handler) {
  console.error("Pi watch command was not registered");
  process.exit(1);
}
const result = await handler("", {
  ui: {
    notify(message) {
      notification = message;
    },
  },
});
if (result !== undefined) {
  console.error(`Pi command returned a value: ${String(result)}`);
  process.exit(1);
}
if (!notification.includes("started Pi extension arm child")) {
  console.error(notification);
  process.exit(1);
}
for (let i = 0; i < 50 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) {
  console.error(`missing follow-up prompt: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("external healthy watcher")) {
  console.error(prompt);
  process.exit(1);
}
if (!prompt.includes("watcher: healthy pid=1")) {
  console.error(prompt);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi extension must surface an external healthy watcher as an owned-wake failure"
  [ -z "$out" ] || fail "Pi external-healthy test printed output: $out"
  pass "Pi extension reports external healthy watcher output"
}

test_pi_tool_returns_agent_tool_result() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-tool-result-root"
  home="$TMP_ROOT/pi-tool-result-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
if (tool.label !== "Arm firstmate watcher") throw new Error(`unexpected label: ${tool.label}`);
if (tool.parameters?.type !== "object") throw new Error("tool parameters are not a TypeBox object schema");
const result = await tool.execute("tool-call-1", {}, undefined, undefined, {});
if (!Array.isArray(result.content) || result.content[0]?.type !== "text") {
  throw new Error(`invalid tool content: ${JSON.stringify(result)}`);
}
if (!result.content[0].text.includes("started Pi extension arm child")) {
  throw new Error(`unexpected tool text: ${result.content[0].text}`);
}
if (result.details?.ok !== true || result.details?.message !== result.content[0].text) {
  throw new Error(`invalid tool details: ${JSON.stringify(result.details)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi custom tool must return Pi's AgentToolResult shape"
  [ -z "$out" ] || fail "Pi tool-result test printed output: $out"
  pass "Pi custom tool returns text content and structured details"
}

test_pi_stale_lock_recovers_through_home_protocol() {
  local repo home plugin lock_log arm_log probe out status
  repo="$TMP_ROOT/pi-stale-lock-root"
  home="$TMP_ROOT/pi-stale-lock-home"
  lock_log="$TMP_ROOT/pi-stale-lock-protocol.log"
  arm_log="$TMP_ROOT/pi-stale-lock-arm.log"
  probe="$TMP_ROOT/pi-stale-lock-probe.mjs"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf 'invoked\n' >> "${FM_LOCK_LOG:?}"
exec "${FM_REAL_LOCK:?}" "$@"
SH
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-lock.sh" "$repo/bin/fm-watch-arm.sh"
  cat > "$probe" <<'EOF'
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

process.title = "pi";
let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, "999999\n");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const result = await tool.execute("stale-lock", {}, undefined, undefined, {});
if (result.details?.ok !== true) throw new Error(result.content?.[0]?.text || "stale lock recovery failed");
const owner = readFileSync(`${process.env.FM_HOME}/state/.lock`, "utf8").trim();
let pid = String(process.pid);
let attached = false;
for (let i = 0; i < 8 && pid && pid !== "1"; i += 1) {
  if (pid === owner) {
    attached = true;
    break;
  }
  pid = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" }).stdout.trim();
}
if (!attached) {
  throw new Error("home lock protocol did not assign ownership to the attached Pi process");
}
for (let i = 0; i < 50 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("watch arm did not run after stale lock recovery");
EOF
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_LOCK_LOG="$lock_log" \
    FM_REAL_LOCK="$ROOT/bin/fm-lock.sh" FM_ARM_LOG="$arm_log" node "$probe" 2>&1)
  status=$?
  expect_code 0 "$status" "Pi watcher must recover a stale dead lock through fm-lock.sh before arming"
  [ "$(wc -l < "$lock_log" | tr -d ' ')" -eq 1 ] || fail "Pi stale-lock recovery invoked fm-lock.sh more than once"
  [ -z "$out" ] || fail "Pi stale-lock recovery test printed output: $out"
  pass "Pi stale lock recovers through the home-scoped lock protocol"
}

test_pi_live_non_harness_lock_is_reclaimed() {
  local repo home plugin lock_log arm_log probe out status
  repo="$TMP_ROOT/pi-reused-lock-root"
  home="$TMP_ROOT/pi-reused-lock-home"
  lock_log="$TMP_ROOT/pi-reused-lock-protocol.log"
  arm_log="$TMP_ROOT/pi-reused-lock-arm.log"
  probe="$TMP_ROOT/pi-reused-lock-probe.mjs"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf 'invoked\n' >> "${FM_LOCK_LOG:?}"
exec "${FM_REAL_LOCK:?}" "$@"
SH
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-lock.sh" "$repo/bin/fm-watch-arm.sh"
  cat > "$probe" <<'EOF'
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

process.title = "pi";
const unrelated = spawn("sleep", ["300"], { stdio: "ignore" });
await new Promise((resolve, reject) => {
  unrelated.once("spawn", resolve);
  unrelated.once("error", reject);
});
let tool = null;
try {
  const pi = {
    on() {},
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendMessage: async () => {},
  };
  writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${unrelated.pid}\n`);
  const mod = await import(pathToFileURL(process.env.PLUGIN).href);
  mod.default(pi);
  if (!existsSync(`${process.env.FM_HOME}/state/.pi-watch-extension-loaded`)) {
    throw new Error("canonical stale/non-harness classification did not publish the loaded marker");
  }
  const result = await tool.execute("reused-non-harness-lock", {}, undefined, undefined, {});
  if (result.details?.ok !== true) throw new Error(result.content?.[0]?.text || "non-harness lock recovery failed");
  const owner = readFileSync(`${process.env.FM_HOME}/state/.lock`, "utf8").trim();
  let pid = String(process.pid);
  let attached = false;
  for (let i = 0; i < 8 && pid && pid !== "1"; i += 1) {
    if (pid === owner) {
      attached = true;
      break;
    }
    pid = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" }).stdout.trim();
  }
  if (!attached) throw new Error(`lock protocol retained unrelated live pid ${owner}`);
  for (let i = 0; i < 50 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("watch arm did not run after non-harness lock recovery");
} finally {
  unrelated.kill("SIGTERM");
  await new Promise((resolve) => unrelated.once("close", resolve));
}
EOF
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_LOCK_LOG="$lock_log" \
    FM_REAL_LOCK="$ROOT/bin/fm-lock.sh" FM_ARM_LOG="$arm_log" node "$probe" 2>&1)
  status=$?
  expect_code 0 "$status" "Pi watcher must reclaim a live non-harness PID through fm-lock.sh"
  [ "$(wc -l < "$lock_log" | tr -d ' ')" -eq 2 ] || fail "Pi non-harness recovery did not run canonical status plus acquisition exactly once each"
  [ -z "$out" ] || fail "Pi non-harness lock recovery test printed output: $out"
  pass "Pi live non-harness lock is reclaimed through the canonical protocol"
}

test_pi_live_other_lock_owner_is_refused() {
  local repo home plugin lock_log arm_log probe live_pi_entry out status
  repo="$TMP_ROOT/pi-live-other-root"
  home="$TMP_ROOT/pi-live-other-home"
  lock_log="$TMP_ROOT/pi-live-other-lock-protocol.log"
  arm_log="$TMP_ROOT/pi-live-other-arm.log"
  probe="$TMP_ROOT/pi-live-other-probe.mjs"
  live_pi_entry="$repo/fixture/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  mkdir -p "$(dirname "$live_pi_entry")"
  printf 'setInterval(() => {}, 1000);\n' > "$live_pi_entry"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf 'invoked\n' >> "${FM_LOCK_LOG:?}"
exec "${FM_REAL_LOCK:?}" "$@"
SH
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$repo/bin/fm-lock.sh" "$repo/bin/fm-watch-arm.sh"
  cat > "$probe" <<'EOF'
import { spawn } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const other = spawn(process.execPath, [process.env.FM_LIVE_PI_ENTRY], { stdio: "ignore" });
await new Promise((resolve, reject) => {
  other.once("spawn", resolve);
  other.once("error", reject);
});
let tool = null;
try {
  writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${other.pid}\n`);
  const pi = {
    on() {},
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendMessage: async () => {},
  };
  const mod = await import(pathToFileURL(process.env.PLUGIN).href);
  mod.default(pi);
  if (existsSync(`${process.env.FM_HOME}/state/.pi-watch-extension-loaded`)) {
    throw new Error("verified live other owner allowed this session to publish the loaded marker");
  }
  const result = await tool.execute("live-other-lock", {}, undefined, undefined, {});
  if (result.details?.ok !== false || !result.content?.[0]?.text.includes("read-only")) {
    throw new Error(`unexpected live-other result: ${JSON.stringify(result)}`);
  }
  if (!existsSync(process.env.FM_LOCK_LOG)) throw new Error("fm-lock.sh did not classify the live other owner");
  if (existsSync(process.env.FM_ARM_LOG)) throw new Error("watch arm ran against a live other owner");
} finally {
  other.kill("SIGTERM");
  await new Promise((resolve) => other.once("close", resolve));
}
EOF
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_LOCK_LOG="$lock_log" \
    FM_LIVE_PI_ENTRY="$live_pi_entry" \
    FM_REAL_LOCK="$ROOT/bin/fm-lock.sh" FM_ARM_LOG="$arm_log" node "$probe" 2>&1)
  status=$?
  expect_code 0 "$status" "Pi watcher must let fm-lock.sh refuse a verified live other session owner"
  [ "$(wc -l < "$lock_log" | tr -d ' ')" -eq 2 ] || fail "Pi live-owner refusal did not run canonical status plus acquisition exactly once each"
  [ -z "$out" ] || fail "Pi live-other lock test printed output: $out"
  pass "Pi verified live other lock owner remains read-only"
}

test_session_lock_recognizes_only_verified_pi_processes() {
  local home state fakebin holder out
  home="$TMP_ROOT/session-lock-pi-identity-home"
  state="$home/state"
  fakebin=$(fm_fakebin "$TMP_ROOT/session-lock-pi-identity-fakebin")
  mkdir -p "$state"
  sleep 300 & holder=$!
  printf '%s\n' "$holder" > "$state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "$FM_TEST_COMM" ;;
  *"args="*) printf '%s\n' "$FM_TEST_ARGS" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_COMM=/opt/bin/pi \
    FM_TEST_ARGS='/opt/bin/pi --model test' "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "held by live harness" "an exact Pi command identity was not recognized as a live lock owner"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_COMM=/usr/bin/node \
    FM_TEST_ARGS='/usr/bin/node /opt/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js --model test' \
    "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "held by live harness" "the verified Pi Node entrypoint was not recognized as a live lock owner"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_COMM=/usr/bin/node \
    FM_TEST_ARGS='/usr/bin/node /opt/pi-helper.js' "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "stale" "a generic Node process was trusted as a live Pi lock owner"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_COMM=/usr/bin/node \
    FM_TEST_ARGS='/usr/bin/node /opt/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js.evil' \
    "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "stale" "a suffixed Pi entrypoint argument was trusted as a live lock owner"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_COMM=/usr/bin/node \
    FM_TEST_ARGS='/usr/bin/node /opt/innocent.js /opt/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js' \
    "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "stale" "a later-argument Pi entrypoint spoof was trusted as a live lock owner"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_COMM=/opt/bin/pi \
    FM_TEST_ARGS='/usr/bin/node server.js' "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "stale" "a Pi comm without a matching Pi argv identity was trusted as a live lock owner"

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "session lock recognizes only verified Pi process identities"
}

test_session_lock_reclaim_has_one_atomic_winner() {
  local home state fakebin barrier stale holder_a holder_b mutex_dead claim_a claim_b rc_a rc_b wins owner
  home="$TMP_ROOT/session-lock-race-home"
  state="$home/state"
  fakebin="$TMP_ROOT/session-lock-race-fakebin"
  barrier="$TMP_ROOT/session-lock-race-barrier"
  mkdir -p "$state" "$fakebin" "$barrier"
  sleep 300 & stale=$!
  sleep 300 & holder_a=$!
  sleep 300 & holder_b=$!
  printf '%s\n' "$stale" > "$state/.lock"
  mutex_dead=999999
  while kill -0 "$mutex_dead" 2>/dev/null; do mutex_dead=$((mutex_dead + 1)); done
  mkdir "$state/.lock.acquire"
  printf '%s\n' "$mutex_dead" > "$state/.lock.acquire/pid"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$*" in
  *"comm="*)
    if [ "$pid" = "$FM_STALE_PID" ]; then
      : > "$FM_BARRIER/$FM_FAKE_HOLDER"
      i=0
      while [ "$(find "$FM_BARRIER" -type f | wc -l | tr -d ' ')" -lt 2 ] && [ "$i" -lt 100 ]; do
        sleep 0.01
        i=$((i + 1))
      done
      printf 'sleep\n'
    elif [ "$pid" = "$FM_HOLDER_A" ] || [ "$pid" = "$FM_HOLDER_B" ]; then
      printf 'pi\n'
    else
      printf 'bash\n'
    fi
    ;;
  *"args="*)
    if [ "$pid" = "$FM_STALE_PID" ]; then
      printf 'sleep 300\n'
    elif [ "$pid" = "$FM_HOLDER_A" ] || [ "$pid" = "$FM_HOLDER_B" ]; then
      printf 'pi\n'
    else
      printf 'bash fm-lock.sh\n'
    fi
    ;;
  *"ppid="*)
    if [ "$pid" = "$FM_HOLDER_A" ] || [ "$pid" = "$FM_HOLDER_B" ]; then printf '1\n'; else printf '%s\n' "$FM_FAKE_HOLDER"; fi
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  claim_a="$TMP_ROOT/session-lock-claim-a"
  claim_b="$TMP_ROOT/session-lock-claim-b"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STALE_PID="$stale" FM_FAKE_HOLDER="$holder_a" \
    FM_HOLDER_A="$holder_a" FM_HOLDER_B="$holder_b" FM_BARRIER="$barrier" \
    "$ROOT/bin/fm-lock.sh" > "$claim_a.out" 2> "$claim_a.err" & claim_a=$!
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STALE_PID="$stale" FM_FAKE_HOLDER="$holder_b" \
    FM_HOLDER_A="$holder_a" FM_HOLDER_B="$holder_b" FM_BARRIER="$barrier" \
    "$ROOT/bin/fm-lock.sh" > "$claim_b.out" 2> "$claim_b.err" & claim_b=$!
  rc_a=0
  wait "$claim_a" || rc_a=$?
  rc_b=0
  wait "$claim_b" || rc_b=$?
  kill "$stale" "$holder_a" "$holder_b" 2>/dev/null || true
  wait "$stale" "$holder_a" "$holder_b" 2>/dev/null || true
  wins=0
  [ "$rc_a" -eq 0 ] && wins=$((wins + 1))
  [ "$rc_b" -eq 0 ] && wins=$((wins + 1))
  [ "$wins" -eq 1 ] || fail "concurrent stale session-lock claims produced $wins winners"
  owner=$(cat "$state/.lock")
  if [ "$rc_a" -eq 0 ]; then
    [ "$owner" = "$holder_a" ] || fail "winning claimant A did not retain the session lock"
  else
    [ "$owner" = "$holder_b" ] || fail "winning claimant B did not retain the session lock"
  fi
  [ -z "$(find "$state" -name '.lock.acquire*' -print -quit)" ] || fail "session-lock acquisition mutex state survived cleanup"
  [ -z "$(find "$state" -name '.lock.write.*' -print -quit)" ] || fail "session-lock temporary record survived cleanup"
  pass "concurrent stale session-lock reclaim has one atomic winner"
}

test_pi_process_exit_cleanup_listener_lifecycle() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-exit-listener-root"
  home="$TMP_ROOT/pi-exit-listener-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool() {},
  sendMessage: async () => {},
};
const before = process.listenerCount("exit");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("Pi extension did not install exactly one process-exit fallback");
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
if (process.listenerCount("exit") !== before) {
  throw new Error("session_shutdown did not remove the process-exit fallback");
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi cleanup fallback listener must install once and unregister on session shutdown"
  [ -z "$out" ] || fail "Pi listener-lifecycle test printed output: $out"
  pass "Pi process-exit cleanup listener has a bounded lifecycle"
}

test_pi_session_shutdown_suppresses_intentional_exit() {
  local repo home plugin cleanup_log pid_file out status
  repo="$TMP_ROOT/pi-shutdown-root"
  home="$TMP_ROOT/pi-shutdown-home"
  cleanup_log="$TMP_ROOT/pi-shutdown-cleaned"
  pid_file="$TMP_ROOT/pi-shutdown-child.pid"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'printf "cleaned\n" > "$FM_CLEANUP_LOG"; trap - TERM; kill -TERM $$' TERM
printf '%s\n' "$$" > "$FM_CHILD_PID_FILE"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_PI_WATCH_STOP_GRACE_MS=3000 \
    FM_CLEANUP_LOG="$cleanup_log" FM_CHILD_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let tool = null;
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage: async () => {
    prompts += 1;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-shutdown", {}, undefined, undefined, {});
for (let i = 0; i < 50 && !existsSync(process.env.FM_CHILD_PID_FILE); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_CHILD_PID_FILE)) throw new Error("arm child did not start");
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "reload" }, {});
if (!existsSync(process.env.FM_CLEANUP_LOG)) throw new Error("session_shutdown returned before child cleanup settled");
await new Promise((resolve) => setTimeout(resolve, 80));
if (prompts !== 0) throw new Error(`intentional shutdown emitted ${prompts} watcher follow-ups`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi reload shutdown must await cleanup and suppress the intentional SIGTERM wake"
  [ -z "$out" ] || fail "Pi intentional-shutdown test printed output: $out"
  pass "Pi session shutdown awaits arm cleanup without a false watcher wake"
}

test_pi_session_shutdown_cancels_pending_lock_claim() {
  local repo home plugin lock_started lock_release arm_log out status
  repo="$TMP_ROOT/pi-pending-shutdown-root"
  home="$TMP_ROOT/pi-pending-shutdown-home"
  lock_started="$TMP_ROOT/pi-pending-shutdown-lock-started"
  lock_release="$TMP_ROOT/pi-pending-shutdown-lock-release"
  arm_log="$TMP_ROOT/pi-pending-shutdown-arm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
set -u
: > "${FM_LOCK_STARTED:?}"
while [ ! -f "${FM_LOCK_RELEASE:?}" ]; do sleep 0.01; done
printf '%s\n' "$PPID" > "$FM_HOME/state/.lock"
SH
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
mkdir -p "$FM_HOME/state/.watch.lock"
printf 'signal: orphaned arm\n'
SH
  chmod +x "$repo/bin/fm-lock.sh" "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_LOCK_STARTED="$lock_started" \
    FM_LOCK_RELEASE="$lock_release" FM_ARM_LOG="$arm_log" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let tool = null;
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage: async () => {
    prompts += 1;
  },
};
const before = process.listenerCount("exit");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const start = tool.execute("pending-shutdown", {}, undefined, undefined, {});
for (let i = 0; i < 100 && !existsSync(process.env.FM_LOCK_STARTED); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_LOCK_STARTED)) throw new Error("delayed lock claim did not start");
let shutdownSettled = false;
const shutdown = Promise.resolve(handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {})).then(() => {
  shutdownSettled = true;
});
await new Promise((resolve) => setTimeout(resolve, 40));
if (shutdownSettled) throw new Error("session_shutdown returned before the pending lock claim settled");
writeFileSync(process.env.FM_LOCK_RELEASE, "release\n");
const [result] = await Promise.all([start, shutdown]);
if (result.details?.ok !== false || !result.content?.[0]?.text.includes("session shut down")) {
  throw new Error(`unexpected cancelled-start result: ${JSON.stringify(result)}`);
}
await new Promise((resolve) => setTimeout(resolve, 80));
if (existsSync(process.env.FM_ARM_LOG)) throw new Error("arm child started after pending shutdown");
if (existsSync(`${process.env.FM_HOME}/state/.watch.lock`)) throw new Error("watcher state survived pending shutdown");
if (prompts !== 0) throw new Error(`pending shutdown emitted ${prompts} watcher follow-ups`);
const coordinator = [...globalThis.__firstmatePiWatchCoordinators.values()][0];
if (coordinator && (coordinator.current || coordinator.startPromise || coordinator.state !== "idle")) {
  throw new Error(`coordinator survived pending shutdown: ${coordinator.state}`);
}
if (process.listenerCount("exit") !== before) throw new Error("pending shutdown retained the process-exit listener");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi shutdown must cancel and await a pending session-lock claim"
  [ -z "$out" ] || fail "Pi pending-lock shutdown test printed output: $out"
  pass "Pi session shutdown cancels pending lock startup without an orphan or false wake"
}

test_pi_custom_wake_is_structured_and_not_user_authored() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-custom-wake-root"
  home="$TMP_ROOT/pi-custom-wake-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'signal: structured wake\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const deliveries = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage(message, options) {
    deliveries.push({ message, options });
  },
  sendUserMessage() {
    throw new Error("watcher wake was delivered as a user-role message");
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("structured-wake", {}, undefined, undefined, {});
for (let i = 0; i < 50 && deliveries.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (deliveries.length !== 1) throw new Error(`expected one custom wake, saw ${deliveries.length}`);
const { message, options } = deliveries[0];
if (message.customType !== "firstmate-watcher-wake") throw new Error(`wrong custom type: ${message.customType}`);
if (message.display !== true) throw new Error("custom wake is not persisted/displayed");
if (!message.content.includes("FIRSTMATE WATCHER WAKE: signal: structured wake")) throw new Error(message.content);
if (message.details?.kind !== "actionable" || message.details?.generation !== 1) {
  throw new Error(`invalid structured details: ${JSON.stringify(message.details)}`);
}
if (options?.deliverAs !== "followUp" || options?.triggerTurn !== true) {
  throw new Error(`invalid delivery options: ${JSON.stringify(options)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi watcher wake must persist as a custom background event that triggers an agent turn"
  [ -z "$out" ] || fail "Pi structured-wake test printed output: $out"
  pass "Pi watcher wake is a custom follow-up turn, never a user-role message"
}

test_pi_unexpected_actionable_exit_notifies_once() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-actionable-root"
  home="$TMP_ROOT/pi-actionable-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'signal: synthetic actionable wake\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage: async (message) => {
    prompts.push(message);
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-actionable", {}, undefined, undefined, {});
for (let i = 0; i < 50 && prompts.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (prompts.length !== 1) throw new Error(`expected one actionable follow-up, saw ${prompts.length}`);
if (!prompts[0].content.includes("signal: synthetic actionable wake")) throw new Error(prompts[0].content);
await new Promise((resolve) => setTimeout(resolve, 80));
if (prompts.length !== 1) throw new Error(`actionable close notified ${prompts.length} times`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi actionable arm completion must notify exactly once"
  [ -z "$out" ] || fail "Pi actionable-exit test printed output: $out"
  pass "Pi unexpected actionable arm completion notifies once"
}

test_pi_unexpected_signaled_exit_notifies_once() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-signaled-root"
  home="$TMP_ROOT/pi-signaled-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exec sleep 300
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage: async (message) => {
    prompts.push(message);
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-signaled", {}, undefined, undefined, {});
const coordinator = [...globalThis.__firstmatePiWatchCoordinators.values()][0];
const record = coordinator.current;
if (!record) throw new Error("signaled arm child did not start");
record.child.kill("SIGTERM");
for (let i = 0; i < 50 && prompts.length === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (prompts.length !== 1) throw new Error(`expected one signaled-exit follow-up, saw ${prompts.length}`);
if (!prompts[0].content.includes("terminated by SIGTERM")) throw new Error(prompts[0].content);
record.child.emit("error", new Error("synthetic post-close error"));
record.child.emit("close", null, "SIGKILL");
await new Promise((resolve) => setTimeout(resolve, 80));
if (prompts.length !== 1) throw new Error(`signaled exit notified ${prompts.length} times after duplicate completion events`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi non-intentional signaled arm exit must notify exactly once"
  [ -z "$out" ] || fail "Pi signaled-exit test printed output: $out"
  pass "Pi unexpected signaled arm exit notifies once"
}

test_pi_spawn_error_then_close_notifies_once() {
  local repo home plugin node_bin out status
  repo="$TMP_ROOT/pi-spawn-error-root"
  home="$TMP_ROOT/pi-spawn-error-home"
  node_bin=$(command -v node)
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  : > "$repo/.fm-secondmate-home"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PATH=/nonexistent PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" "$node_bin" --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const deliveries = [];
const pi = {
  on() {}, registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendMessage(message) { deliveries.push(message); },
  sendUserMessage() { throw new Error("unexpected user-role wake"); },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("spawn-error", {}, undefined, undefined, {});
for (let i = 0; i < 50 && deliveries.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 20));
if (deliveries.length !== 1) throw new Error(`expected one spawn-error wake, saw ${deliveries.length}`);
if (!deliveries[0].content.includes("failed: spawn bash ENOENT")) throw new Error(deliveries[0].content);
await new Promise((resolve) => setTimeout(resolve, 80));
if (deliveries.length !== 1) throw new Error(`error plus close delivered ${deliveries.length} wakes`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi arm spawn error plus close must emit exactly one failure wake"
  [ -z "$out" ] || fail "Pi spawn-error test printed output: $out"
  pass "Pi arm error plus close delivers one failure only"
}

test_pi_unexpected_empty_exit_notifies_once() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-empty-exit-root"
  home="$TMP_ROOT/pi-empty-exit-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const deliveries = [];
const pi = {
  on() {}, registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendMessage(message) { deliveries.push(message); },
  sendUserMessage() { throw new Error("unexpected user-role wake"); },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("empty-exit", {}, undefined, undefined, {});
for (let i = 0; i < 50 && deliveries.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 20));
if (deliveries.length !== 1) throw new Error(`expected one empty-exit failure, saw ${deliveries.length}`);
if (!deliveries[0].content.includes("exited unexpectedly with code 0")) throw new Error(deliveries[0].content);
if (deliveries[0].details?.kind !== "failure") throw new Error(JSON.stringify(deliveries[0].details));
EOF
)
  status=$?
  expect_code 0 "$status" "Pi empty zero arm exit must emit exactly one failure wake"
  [ -z "$out" ] || fail "Pi empty-exit test printed output: $out"
  pass "Pi unexpected empty zero exit notifies once"
}

test_pi_actionable_streams_deliver_once_and_capture_is_bounded() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-bounded-output-root"
  home="$TMP_ROOT/pi-bounded-output-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'sig'
printf 'nal: first actionable\n'
printf 'signal: second actionable\n' >&2
head -c 1048576 /dev/zero | tr '\0' x
head -c 1048576 /dev/zero | tr '\0' y >&2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const deliveries = [];
const pi = {
  on() {}, registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendMessage(message) { deliveries.push(message); },
  sendUserMessage() { throw new Error("unexpected user-role wake"); },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("bounded-output", {}, undefined, undefined, {});
for (let i = 0; i < 100 && deliveries.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 20));
if (deliveries.length !== 1) throw new Error(`expected one actionable wake, saw ${deliveries.length}`);
if (!deliveries[0].content.includes("signal: first actionable")) throw new Error(deliveries[0].content);
if (deliveries[0].details?.truncated !== true) throw new Error(`missing truncation details: ${JSON.stringify(deliveries[0].details)}`);
const coordinator = [...globalThis.__firstmatePiWatchCoordinators.values()][0];
const completed = coordinator.lastCompleted;
if (!completed) throw new Error("coordinator did not retain bounded completion diagnostics");
if (completed.stdout.length > 32768 || completed.stderr.length > 32768) {
  throw new Error(`unbounded capture: stdout=${completed.stdout.length} stderr=${completed.stderr.length}`);
}
await new Promise((resolve) => setTimeout(resolve, 80));
if (deliveries.length !== 1) throw new Error(`both streams delivered ${deliveries.length} wakes`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi watcher output must be bounded while split and duplicate actionable lines deliver once"
  [ -z "$out" ] || fail "Pi bounded-output test printed output: $out"
  pass "Pi watcher output capture is bounded and actionable delivery remains exactly once"
}

test_pi_session_shutdown_kills_entire_process_group() {
  local repo home plugin pids out status arm_pid descendant_pid
  repo="$TMP_ROOT/pi-process-group-root"
  home="$TMP_ROOT/pi-process-group-home"
  pids="$TMP_ROOT/pi-process-group-pids"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM
( trap '' TERM; exec >/dev/null 2>&1; while :; do sleep 1; done ) &
printf '%s %s\n' "$$" "$!" > "$FM_GROUP_PIDS"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_GROUP_PIDS="$pids" \
    FM_PI_WATCH_STOP_GRACE_MS=40 node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let tool = null;
const deliveries = [];
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendMessage(message) { deliveries.push(message); },
  sendUserMessage() { throw new Error("unexpected user-role wake"); },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("process-group", {}, undefined, undefined, {});
for (let i = 0; i < 100 && !existsSync(process.env.FM_GROUP_PIDS); i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
if (!existsSync(process.env.FM_GROUP_PIDS)) throw new Error("arm process group did not start");
const started = Date.now();
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "reload" }, {});
if (Date.now() - started > 1000) throw new Error("bounded process-group stop exceeded one second");
if (deliveries.length !== 0) throw new Error(`intentional group stop emitted ${deliveries.length} wakes`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi session shutdown must kill the entire detached arm process group within a bound"
  [ -z "$out" ] || fail "Pi process-group shutdown test printed output: $out"
  read -r arm_pid descendant_pid < "$pids"
  kill -0 "$arm_pid" 2>/dev/null && fail "Pi arm process $arm_pid survived bounded group cleanup"
  kill -0 "$descendant_pid" 2>/dev/null && fail "Pi watcher descendant $descendant_pid survived bounded group cleanup"
  pass "Pi session shutdown kills the entire arm process group without a wake"
}

test_pi_duplicate_factories_share_one_arm() {
  local repo_a repo_b home log out status
  repo_a="$TMP_ROOT/pi-factory-a"
  repo_b="$TMP_ROOT/pi-factory-b"
  home="$TMP_ROOT/pi-factory-home"
  log="$TMP_ROOT/pi-factory-children.log"
  mkdir -p "$repo_a/bin" "$repo_b/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo_a"
  install_pi_watch_extension_fixture "$repo_b"
  cat > "$repo_a/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 143' TERM
printf '%s\n' "$$" >> "$FM_CHILD_LOG"
while :; do sleep 1; done
SH
  cat > "$repo_a/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf 'claim\n' >> "$FM_LOCK_LOG"
sleep 0.2
printf '%s\n' "$PPID" > "$FM_HOME/state/.lock"
SH
  cp "$repo_a/bin/fm-watch-arm.sh" "$repo_b/bin/fm-watch-arm.sh"
  cp "$repo_a/bin/fm-lock.sh" "$repo_b/bin/fm-lock.sh"
  chmod +x "$repo_a/bin/fm-watch-arm.sh" "$repo_b/bin/fm-watch-arm.sh" "$repo_a/bin/fm-lock.sh" "$repo_b/bin/fm-lock.sh"
  out=$(PLUGIN_A="$repo_a/.pi/extensions/fm-primary-pi-watch.ts" PLUGIN_B="$repo_b/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo_a" FM_CHILD_LOG="$log" FM_LOCK_LOG="$home/lock-claims" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = [];
const tools = [];
const makePi = () => ({
  on(event, handler) {
    if (event === "session_shutdown") handlers.push(handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tools.push(candidate);
  },
  sendMessage: async () => {},
});
const a = await import(pathToFileURL(process.env.PLUGIN_A).href);
const b = await import(`${pathToFileURL(process.env.PLUGIN_B).href}?copy=b`);
a.default(makePi());
b.default(makePi());
await Promise.all([
  tools[0].execute("factory-a", {}, undefined, undefined, {}),
  tools[1].execute("factory-b", {}, undefined, undefined, {}),
]);
for (let i = 0; i < 50 && !existsSync(process.env.FM_CHILD_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
const children = readFileSync(process.env.FM_CHILD_LOG, "utf8").trim().split("\n").filter(Boolean);
if (children.length !== 1) throw new Error(`duplicate factories started ${children.length} arm children`);
const claims = readFileSync(process.env.FM_LOCK_LOG, "utf8").trim().split("\n").filter(Boolean);
if (claims.length !== 1) throw new Error(`duplicate factories started ${claims.length} lock claims`);
for (const shutdown of handlers) await shutdown({ type: "session_shutdown", reason: "quit" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi extension factories in one process/home must share one arm coordinator"
  [ -z "$out" ] || fail "Pi duplicate-factory test printed output: $out"
  pass "Pi duplicate extension factories share one attached arm child"
}

test_pi_reload_routes_wake_only_to_current_client() {
  local repo home plugin release out status
  repo="$TMP_ROOT/pi-reload-client-root"
  home="$TMP_ROOT/pi-reload-client-home"
  release="$TMP_ROOT/pi-reload-client-release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
while [ ! -f "$FM_RELEASE" ]; do sleep 0.01; done
printf 'signal: reload client wake\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_RELEASE="$release" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const oldHandlers = new Map();
const newHandlers = new Map();
let oldTool = null;
let oldDeliveries = 0;
let newDeliveries = 0;
const oldPi = {
  on(event, handler) { oldHandlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") oldTool = candidate; },
  sendMessage() { oldDeliveries += 1; },
};
const newPi = {
  on(event, handler) { newHandlers.set(event, handler); },
  registerCommand() {},
  registerTool() {},
  sendMessage() { newDeliveries += 1; },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const url = pathToFileURL(process.env.PLUGIN).href;
const oldModule = await import(`${url}?client=old`);
oldModule.default(oldPi);
await oldTool.execute("reload-client", {}, undefined, undefined, {});
const newModule = await import(`${url}?client=new`);
newModule.default(newPi);
await oldHandlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "reload" }, {});
writeFileSync(process.env.FM_RELEASE, "release\n");
for (let i = 0; i < 100 && newDeliveries === 0; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (oldDeliveries !== 0) throw new Error(`stale Pi send closure received ${oldDeliveries} wakes`);
if (newDeliveries !== 1) throw new Error(`current Pi send closure received ${newDeliveries} wakes`);
await newHandlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "Pi reload must retire stale send closures without stopping the shared current arm"
  [ -z "$out" ] || fail "Pi reload-client test printed output: $out"
  pass "Pi reload routes the shared arm wake only through the current client closure"
}

test_pi_stale_callback_cannot_clear_replacement() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-stale-callback-root"
  home="$TMP_ROOT/pi-stale-callback-home"
  log="$TMP_ROOT/pi-stale-callback-children.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 143' TERM
printf '%s\n' "$$" >> "$FM_CHILD_LOG"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CHILD_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let tool = null;
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage: async () => {
    prompts += 1;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("old-generation", {}, undefined, undefined, {});
const registry = globalThis.__firstmatePiWatchCoordinators;
if (!(registry instanceof Map)) throw new Error("process-wide Pi watch coordinator registry missing");
const coordinator = [...registry.values()][0];
if (!coordinator?.current) throw new Error("old arm generation missing");
const old = coordinator.current;
old.intentionalStopReason = "ownership-transfer";
old.child.emit("error", new Error("synthetic old-generation completion"));
await new Promise((resolve) => setTimeout(resolve, 20));
await tool.execute("new-generation", {}, undefined, undefined, {});
const replacement = coordinator.current;
if (!replacement || replacement === old) throw new Error("replacement generation did not start");
old.child.emit("close", 143);
await new Promise((resolve) => setTimeout(resolve, 80));
if (coordinator.current !== replacement) throw new Error("stale callback cleared the replacement generation");
if (prompts !== 0) throw new Error(`stale intentional generation emitted ${prompts} follow-ups`);
old.child.kill("SIGTERM");
await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
EOF
)
  status=$?
  expect_code 0 "$status" "A stale Pi arm callback must not clear or notify over a replacement generation"
  [ -z "$out" ] || fail "Pi stale-callback test printed output: $out"
  pass "Pi stale arm callback cannot clear or notify over its replacement"
}

test_pi_process_exit_cleanup_stops_arm_child() {
  local repo home plugin cleanup_log pid_file out status pid i
  repo="$TMP_ROOT/pi-process-exit-root"
  home="$TMP_ROOT/pi-process-exit-home"
  cleanup_log="$TMP_ROOT/pi-process-exit-cleaned"
  pid_file="$TMP_ROOT/pi-process-exit-child.pid"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'printf "cleaned\n" > "$FM_CLEANUP_LOG"; exit 0' TERM
printf '%s\n' "$$" > "$FM_CHILD_PID_FILE"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CLEANUP_LOG="$cleanup_log" FM_CHILD_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-exit", {}, undefined, undefined, {});
for (let i = 0; i < 50 && !existsSync(process.env.FM_CHILD_PID_FILE); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_CHILD_PID_FILE)) throw new Error("arm child did not start");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi process exit must run the watcher cleanup fallback"
  [ -z "$out" ] || fail "Pi process-exit cleanup test printed output: $out"
  pid=$(cat "$pid_file")
  i=0
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.02
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "Pi arm child $pid survived process-exit cleanup"
  fi
  pass "Pi process-exit cleanup stops the attached arm child"
}

test_pi_0806_custom_wake_runtime_semantics() {
  local pi_package out status
  pi_package=$(installed_pi_package_dir)
  [ -f "$pi_package/dist/core/agent-session.js" ] || fail "Pi 0.80.6 runtime is required for custom wake semantics coverage"
  out=$(PI_AGENT_SESSION="$pi_package/dist/core/agent-session.js" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const { AgentSession } = await import(pathToFileURL(process.env.PI_AGENT_SESSION).href);
const message = {
  customType: "firstmate-watcher-wake",
  content: "FIRSTMATE WATCHER WAKE: signal: runtime probe",
  display: true,
  details: { generation: 7, kind: "actionable", reason: "signal: runtime probe" },
};
const options = { deliverAs: "followUp", triggerTurn: true };
let idlePrompt = null;
const idleSession = {
  isStreaming: false,
  async _runAgentPrompt(appMessage) { idlePrompt = appMessage; },
};
await AgentSession.prototype.sendCustomMessage.call(idleSession, message, options);
if (!idlePrompt) throw new Error("idle custom wake did not trigger an agent turn");
if (idlePrompt.role !== "custom" || idlePrompt.customType !== "firstmate-watcher-wake") {
  throw new Error(`idle wake was not a custom event: ${JSON.stringify(idlePrompt)}`);
}
if (idlePrompt.display !== true || idlePrompt.details?.generation !== 7) {
  throw new Error(`idle custom wake lost persisted fields: ${JSON.stringify(idlePrompt)}`);
}
if (idlePrompt.role === "user") throw new Error("idle wake impersonated a user message");

let followUp = null;
const streamingSession = {
  isStreaming: true,
  agent: {
    followUp(appMessage) { followUp = appMessage; },
    steer() { throw new Error("watcher wake steered an active turn"); },
  },
  async _runAgentPrompt() { throw new Error("streaming wake started a parallel turn"); },
};
await AgentSession.prototype.sendCustomMessage.call(streamingSession, message, options);
if (!followUp || followUp.role !== "custom" || followUp.customType !== "firstmate-watcher-wake") {
  throw new Error(`streaming wake was not queued as a custom follow-up: ${JSON.stringify(followUp)}`);
}
if (followUp.role === "user") throw new Error("streaming wake impersonated a user message");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi 0.80.6 must trigger idle turns and queue streaming custom watcher follow-ups"
  [ -z "$out" ] || fail "Pi runtime custom-message test printed output: $out"
  pass "Pi 0.80.6 persists watcher wakes as custom events and triggers or queues the correct turn"
}

test_pi_live_acceptance_helper_records_isolated_evidence() {
  local helper home pi_dir evidence fakebin candidate out status hash_count
  helper="$ROOT/tests/fm-pi-live-acceptance-helper.sh"
  home="$TMP_ROOT/pi-acceptance-helper-home"
  pi_dir="$TMP_ROOT/pi-acceptance-helper-agent"
  evidence="$TMP_ROOT/pi-acceptance-helper-evidence"
  fakebin=$(fm_fakebin "$TMP_ROOT/pi-acceptance-helper-fakebin")
  candidate=$(git -C "$ROOT" rev-parse HEAD)
  mkdir -p "$home/state/.watch.lock" "$pi_dir"
  printf '12345\n' > "$home/state/.lock"
  printf '54321\n' > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  printf 'synthetic identity\n' > "$home/state/.watch.lock/pid-identity"
  touch "$home/state/.last-watcher-beat"
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '0.80.6\n'; else printf 'No packages installed.\n'; fi
SH
  chmod +x "$fakebin/pi"
  out=$(PATH="$fakebin:$PATH" FM_PI_ACCEPTANCE_ID=accept-helper-1 FM_PI_CANDIDATE_COMMIT="$candidate" \
    FM_PI_ACCEPTANCE_EVIDENCE="$evidence" PI_CODING_AGENT_DIR="$pi_dir" FM_HOME="$home" \
    bash "$helper" inventory 2>&1)
  status=$?
  expect_code 0 "$status" "Pi live acceptance helper must record an isolated inventory"
  assert_contains "$(cat "$evidence/identity.txt")" "acceptance_id=accept-helper-1" "acceptance identity is missing the dedicated id"
  assert_contains "$(cat "$evidence/pi-list.txt")" "No packages installed." "acceptance inventory did not prove the Pi package set is empty"
  hash_count=$(wc -l < "$evidence/tracked-extension-hashes.txt" | tr -d ' ')
  [ "$hash_count" -eq 1 ] || fail "acceptance inventory recorded $hash_count tracked Pi extension hashes"
  PATH="$fakebin:$PATH" FM_PI_ACCEPTANCE_ID=accept-helper-1 FM_PI_CANDIDATE_COMMIT="$candidate" \
    FM_PI_ACCEPTANCE_EVIDENCE="$evidence" PI_CODING_AGENT_DIR="$pi_dir" FM_HOME="$home" \
    bash "$helper" emit acceptance-probe >/dev/null
  assert_contains "$(cat "$home/state/acceptance-probe.status")" "done: Pi live acceptance" "acceptance helper did not emit the known actionable status"
  PATH="$fakebin:$PATH" FM_PI_ACCEPTANCE_ID=accept-helper-1 FM_PI_CANDIDATE_COMMIT="$candidate" \
    FM_PI_ACCEPTANCE_EVIDENCE="$evidence" PI_CODING_AGENT_DIR="$pi_dir" FM_HOME="$home" \
    bash "$helper" snapshot armed >/dev/null
  assert_contains "$(cat "$evidence/armed-watcher-lock.txt")" "watcher_pid=54321" "acceptance snapshot omitted watcher ownership"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Linux\n'
SH
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -f ]; then
  printf 'partial-filesystem-stat\n'
  exit 1
fi
if [ "${1:-}" = -c ]; then
  printf '1700000000\n'
  exit 0
fi
exit 2
SH
  chmod +x "$fakebin/uname" "$fakebin/stat"
  PATH="$fakebin:$PATH" FM_PI_ACCEPTANCE_ID=accept-helper-1 FM_PI_CANDIDATE_COMMIT="$candidate" \
    FM_PI_ACCEPTANCE_EVIDENCE="$evidence" PI_CODING_AGENT_DIR="$pi_dir" FM_HOME="$home" \
    bash "$helper" snapshot linux-stat >/dev/null
  assert_contains "$(cat "$evidence/linux-stat-watcher-lock.txt")" "beacon_epoch=1700000000" "Linux acceptance snapshot did not select GNU stat"
  assert_not_contains "$(cat "$evidence/linux-stat-watcher-lock.txt")" "partial-filesystem-stat" "Linux acceptance snapshot retained failed BSD stat output"
  printf 'Reloaded extensions\nwatcher: started Pi extension arm child 3\n' > "$home/reload-transcript.txt"
  PATH="$fakebin:$PATH" FM_PI_ACCEPTANCE_ID=accept-helper-1 FM_PI_CANDIDATE_COMMIT="$candidate" \
    FM_PI_ACCEPTANCE_EVIDENCE="$evidence" PI_CODING_AGENT_DIR="$pi_dir" FM_HOME="$home" \
    bash "$helper" verify-reload "$home/reload-transcript.txt" >/dev/null
  assert_contains "$(cat "$evidence/reload-check.txt")" "watcher_only_reload=clean" "acceptance helper did not verify watcher-only reload output"
  [ -z "$out" ] || fail "Pi acceptance helper printed unexpected output: $out"
  pass "Pi live acceptance helper records portable isolated evidence"
}

test_opencode_primary_watch_plugin_static_wiring() {
  local plugin text
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  assert_present "$plugin" "OpenCode primary watch plugin missing"
  text=$(cat "$plugin")
  assert_contains "$text" "session.idle" "OpenCode plugin does not listen for session.idle"
  assert_contains "$text" "fm-watch-arm.sh" "OpenCode plugin does not spawn the watcher arm"
  assert_contains "$text" "promptAsync" "OpenCode plugin does not wake with promptAsync"
  assert_contains "$text" ".fm-secondmate-home" "OpenCode plugin does not scope out secondmate homes"
  assert_contains "$text" "rev-parse\", \"--git-dir" "OpenCode plugin does not check linked worktree scope"
  assert_contains "$text" "sessionOwnsLock" "OpenCode plugin does not gate arm attempts on the session lock"
  assert_contains "$text" 'fm-watch-arm.sh" --restart' "OpenCode plugin does not restart into its own watcher child"
  assert_contains "$text" 'setArmStatus("external")' "OpenCode plugin still treats an external healthy watcher as armed"
  pass "OpenCode primary watcher plugin has the verified TUI wake wiring"
}

test_opencode_primary_watch_plugin_uses_effective_state_home() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-state-root"
  home="$TMP_ROOT/opencode-effective-state-home"
  log="$TMP_ROOT/opencode-effective-state.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'home=%s root=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 50 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
const expectedRoot = realpathSync(process.env.WORKTREE);
if (!text.includes(`home=${process.env.FM_HOME}`) || !text.includes(`root=${expectedRoot}`)) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must use FM_HOME state outside the repo root"
  [ -z "$out" ] || fail "OpenCode effective-state test printed output: $out"
  pass "OpenCode watcher plugin uses the effective FM_HOME state"
}

test_opencode_primary_watch_plugin_sources_effective_config() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-config-root"
  home="$TMP_ROOT/opencode-effective-config-home"
  log="$TMP_ROOT/opencode-effective-config.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  printf 'export FM_POLL=7\n' > "$home/config/x-mode.env"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'poll=%s\n' "${FM_POLL:-missing}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 50 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
if (!text.includes("poll=7")) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must source FM_HOME config outside the repo root"
  [ -z "$out" ] || fail "OpenCode effective-config test printed output: $out"
  pass "OpenCode watcher plugin sources the effective config"
}

test_opencode_primary_watch_plugin_requires_session_lock() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-lock-root"
  home="$TMP_ROOT/opencode-lock-home"
  log="$TMP_ROOT/opencode-lock.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, "999999\n");
await hooks.event(event);
await new Promise((resolve) => setTimeout(resolve, 120));
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm ran without owning the session lock");
  process.exit(1);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event(event);
for (let i = 0; i < 50 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run after the session lock matched");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must arm only when this session owns the fleet lock"
  [ -z "$out" ] || fail "OpenCode session-lock test printed output: $out"
  pass "OpenCode watcher plugin requires session lock ownership"
}

test_opencode_watch_arm_coordinator_respects_primary_scope() {
  local plugin base repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  base="$TMP_ROOT/opencode-coordinator-base"
  repo="$TMP_ROOT/opencode-coordinator-wt"
  home="$TMP_ROOT/opencode-coordinator-home"
  log="$TMP_ROOT/opencode-coordinator.log"
  fm_git_worktree "$base" "$repo" fm/opencode-coordinator
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
await new Promise((resolve) => setTimeout(resolve, 120));
if (status !== "not-primary") {
  console.error(`expected not-primary, got ${status}`);
  process.exit(1);
}
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("coordinator armed from a linked worktree");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch coordinator must keep primary scope checks in the shared arm path"
  [ -z "$out" ] || fail "OpenCode coordinator-scope test printed output: $out"
  pass "OpenCode watcher coordinator respects primary scope"
}

test_opencode_primary_watch_plugin_rearms_after_wake() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-rearm-root"
  home="$TMP_ROOT/opencode-rearm-home"
  log="$TMP_ROOT/opencode-rearm.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'signal: synthetic wake\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const waitForPrompts = async (expected) => {
  for (let i = 0; i < 50; i += 1) {
    if (prompts >= expected) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  console.error(`expected ${expected} prompts, saw ${prompts}`);
  process.exit(1);
};
const client = {
  session: {
    promptAsync: async () => {
      prompts += 1;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event(event);
await waitForPrompts(1);
await hooks.event(event);
await waitForPrompts(2);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must arm on the idle after a wake follow-up"
  [ -z "$out" ] || fail "OpenCode rearm test printed output: $out"
  pass "OpenCode watcher plugin rearms after a watcher wake"
}

test_opencode_watch_arm_coordinates_with_turnend_guard() {
  local arm_plugin guard_plugin repo home log guard_log out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-coordinate-root"
  home="$TMP_ROOT/opencode-coordinate-home"
  log="$TMP_ROOT/opencode-coordinate-arm.log"
  guard_log="$TMP_ROOT/opencode-coordinate-guard.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=1 (beacon fresh)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard should not run\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 50 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard ran before the watch arm could establish supervision");
  process.exit(1);
}
if (promptBody) {
  console.error(`unexpected prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode turn-end guard must let the auto-arm plugin establish supervision first"
  [ -z "$out" ] || fail "OpenCode coordination test printed output: $out"
  pass "OpenCode watcher plugin coordinates with the turn-end guard"
}

test_opencode_healthy_arm_output_does_not_suppress_guard() {
  local arm_plugin guard_plugin repo home log guard_log out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-external-healthy-root"
  home="$TMP_ROOT/opencode-external-healthy-home"
  log="$TMP_ROOT/opencode-external-healthy-arm.log"
  guard_log="$TMP_ROOT/opencode-external-healthy-guard.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard ran after external healthy watcher\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 50 && !existsSync(process.env.FM_GUARD_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (!readFileSync(process.env.FM_ARM_LOG, "utf8").includes("args=--restart")) {
  console.error("watch arm was not asked to restart into an owned child");
  process.exit(1);
}
if (!existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard was suppressed by an external healthy watcher");
  process.exit(1);
}
if (!promptBody.includes("TURN WOULD END BLIND")) {
  console.error(`missing blind-turn prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must not treat external healthy output as an owned arm"
  [ -z "$out" ] || fail "OpenCode external-healthy test printed output: $out"
  pass "OpenCode healthy arm output does not suppress the turn-end guard"
}

test_tracked_extension_present_and_self_hashing
test_pi_status_loads_offline_before_arm
test_pi_status_successful_arm_watching
test_pi_status_duplicate_arm_preserves_watching
test_pi_status_duplicate_factory_preserves_active_watching
test_pi_status_legacy_coordinator_reload_compatibility
test_pi_status_actionable_wake_and_rearm
test_pi_status_attention_failures
test_pi_status_intentional_stop_offline
test_pi_status_reload_and_quit_clear
test_pi_status_reload_overlap_preserves_replacement_ownership
test_pi_status_stale_generation_cannot_overwrite
test_pi_status_cancelled_start_stays_cleared
test_pi_status_absent_in_task_worktree
test_pi_status_static_non_goals
test_pi_extension_supervises_only_primary_or_secondmate_homes
test_pi_live_lab_cleanup_is_owned
test_pi_detached_launch_helper_preserves_exact_argv
test_spawn_template_mentions_pi_watch_placeholder
test_pi_extension_reports_external_healthy_watcher
test_pi_tool_returns_agent_tool_result
test_pi_stale_lock_recovers_through_home_protocol
test_pi_live_non_harness_lock_is_reclaimed
test_pi_live_other_lock_owner_is_refused
test_session_lock_recognizes_only_verified_pi_processes
test_session_lock_reclaim_has_one_atomic_winner
test_pi_process_exit_cleanup_listener_lifecycle
test_pi_session_shutdown_suppresses_intentional_exit
test_pi_session_shutdown_cancels_pending_lock_claim
test_pi_custom_wake_is_structured_and_not_user_authored
test_pi_unexpected_actionable_exit_notifies_once
test_pi_unexpected_signaled_exit_notifies_once
test_pi_spawn_error_then_close_notifies_once
test_pi_unexpected_empty_exit_notifies_once
test_pi_actionable_streams_deliver_once_and_capture_is_bounded
test_pi_session_shutdown_kills_entire_process_group
test_pi_duplicate_factories_share_one_arm
test_pi_reload_routes_wake_only_to_current_client
test_pi_stale_callback_cannot_clear_replacement
test_pi_process_exit_cleanup_stops_arm_child
test_pi_0806_custom_wake_runtime_semantics
test_pi_live_acceptance_helper_records_isolated_evidence
test_opencode_primary_watch_plugin_static_wiring
test_opencode_primary_watch_plugin_uses_effective_state_home
test_opencode_primary_watch_plugin_sources_effective_config
test_opencode_primary_watch_plugin_requires_session_lock
test_opencode_watch_arm_coordinator_respects_primary_scope
test_opencode_primary_watch_plugin_rearms_after_wake
test_opencode_watch_arm_coordinates_with_turnend_guard
test_opencode_healthy_arm_output_does_not_suppress_guard
