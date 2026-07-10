#!/usr/bin/env bash
# Tests for the tracked Pi primary watcher extension and Pi secondmate wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-watch-extension)
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p "$repo/.pi/extensions" "$repo/node_modules/typebox"
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

test_tracked_extension_present_and_self_hashing() {
  local text expected_config_source
  expected_config_source="config_dir=\\\"\${FM_CONFIG_OVERRIDE:-\$FM_HOME/config}\\\""
  assert_present "$EXT" "tracked Pi primary watcher extension is missing"
  text=$(cat "$EXT")
  assert_contains "$text" "fm_watch_arm_pi" "tracked extension missing tool name"
  assert_contains "$text" "fm-watch-arm-pi" "tracked extension missing command name"
  assert_contains "$text" "fm-watch-arm.sh" "tracked extension missing watcher arm"
  assert_contains "$text" "sendUserMessage" "tracked extension missing Pi wake API"
  assert_contains "$text" "deliverAs: \"followUp\"" "tracked extension missing followUp delivery"
  assert_contains "$text" ".pi-watch-extension-loaded" "tracked extension missing loaded marker"
  assert_contains "$text" 'createHash("sha256").update(readFileSync(extensionFile)).digest("hex")' "tracked extension does not self-hash its own content for extensionVersion"
  assert_contains "$text" 'fileURLToPath(import.meta.url)' "tracked extension does not self-locate via import.meta.url"
  assert_contains "$text" 'type LockOwnership = "owned" | "missing" | "other"' "tracked extension does not distinguish missing lock from another owner"
  assert_contains "$text" "readFileSync(\`\${state}/.lock\`" "tracked extension does not read the effective session lock"
  assert_contains "$text" 'return pidAlive(lockPid) ? "other" : "missing"' "tracked extension does not allow a pre-lock load marker"
  assert_contains "$text" 'if (lockOwnership() !== "owned") await claimSessionLock()' "tracked extension does not delegate every non-owned state to the home lock protocol"
  assert_contains "$text" 'if (lockOwnership() !== "owned") return { ok: false' "tracked extension does not re-check lock ownership after recovery"
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
  assert_not_contains "$text" "[ -f config/x-mode.env ]" "tracked extension kept a repo-relative x-mode config path"
  pass "Pi primary watcher extension is tracked, self-hashing, and self-locating"
}

test_spawn_template_mentions_pi_watch_placeholder() {
  local text
  text=$(cat "$ROOT/bin/fm-spawn.sh")
  assert_contains "$text" "--approve -e __PITURNEND__ -e __PIWATCH__" "Pi secondmate launch template does not approve the home while loading both tracked primary extensions"
  assert_contains "$text" "\$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts" "fm-spawn does not point the Pi secondmate watch placeholder at the tracked extension"
  assert_not_contains "$text" "state/fm-primary-pi-watch.ts" "fm-spawn must never launch a generated Pi watcher copy"
  assert_not_contains "$text" "fm-pi-watch-extension.sh" "fm-spawn should no longer generate the Pi watch extension before launch"
  assert_contains "$text" "__PITURNEND__" "fm-spawn does not replace the Pi turn-end guard extension placeholder"
  assert_contains "$text" "__PIWATCH__" "fm-spawn does not replace the Pi watch extension placeholder"
  pass "Pi secondmate launch wiring includes both tracked primary extensions"
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
  sendUserMessage: async (message) => {
    prompt = message;
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
  sendUserMessage: async () => {},
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
exec "${FM_REAL_LOCK:?}"
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

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
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
exec "${FM_REAL_LOCK:?}"
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
    sendUserMessage: async () => {},
  };
  writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${unrelated.pid}\n`);
  const mod = await import(pathToFileURL(process.env.PLUGIN).href);
  mod.default(pi);
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
  [ "$(wc -l < "$lock_log" | tr -d ' ')" -eq 1 ] || fail "Pi non-harness recovery did not invoke fm-lock.sh exactly once"
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
exec "${FM_REAL_LOCK:?}"
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
    sendUserMessage: async () => {},
  };
  const mod = await import(pathToFileURL(process.env.PLUGIN).href);
  mod.default(pi);
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
  [ "$(wc -l < "$lock_log" | tr -d ' ')" -eq 1 ] || fail "Pi live-owner classification did not invoke fm-lock.sh exactly once"
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
  sendUserMessage: async () => {},
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
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CLEANUP_LOG="$cleanup_log" FM_CHILD_PID_FILE="$pid_file" node --input-type=module 2>&1 <<'EOF'
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
  sendUserMessage: async () => {
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
  sendUserMessage: async () => {
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
if (coordinator.current || coordinator.startPromise || coordinator.state !== "idle") {
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
  sendUserMessage: async (message) => {
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
if (!prompts[0].includes("signal: synthetic actionable wake")) throw new Error(prompts[0]);
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
  sendUserMessage: async (message) => {
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
if (!prompts[0].includes("terminated by SIGTERM")) throw new Error(prompts[0]);
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
  sendUserMessage: async () => {},
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
  sendUserMessage: async () => {
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
  sendUserMessage: async () => {},
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
  i=0
  while [ "$i" -lt 50 ] && [ ! -f "$cleanup_log" ]; do
    sleep 0.02
    i=$((i + 1))
  done
  [ -f "$cleanup_log" ] || fail "Pi process-exit fallback did not deliver TERM to the arm child"
  pid=$(cat "$pid_file")
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "Pi arm child $pid survived process-exit cleanup"
  fi
  pass "Pi process-exit cleanup stops the attached arm child"
}

test_pi_live_acceptance_helper_records_isolated_evidence() {
  local helper home pi_dir evidence fakebin candidate out status
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
  assert_contains "$text" ".fm-secondmate-home" "OpenCode plugin does not recognize marked secondmate supervising homes"
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

test_opencode_watch_arm_coordinator_accepts_marked_secondmate() {
  local plugin base repo log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  base="$TMP_ROOT/opencode-secondmate-base"
  repo="$TMP_ROOT/opencode-secondmate-wt"
  log="$TMP_ROOT/opencode-secondmate.log"
  fm_git_worktree "$base" "$repo" fm/opencode-secondmate
  mkdir -p "$repo/bin" "$repo/state" "$repo/config"
  : > "$repo/AGENTS.md"
  printf 'sm-opencode\n' > "$repo/.fm-secondmate-home"
  : > "$repo/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=1 (beacon fresh)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$repo" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
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
if (status !== "armed") {
  console.error(`expected armed, got ${status}`);
  process.exit(1);
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("coordinator did not arm from a marked secondmate home");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch coordinator must accept a marked persistent secondmate home"
  [ -z "$out" ] || fail "OpenCode marked-secondmate test printed output: $out"
  pass "OpenCode watcher coordinator accepts a marked secondmate supervising home"
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
test_pi_unexpected_actionable_exit_notifies_once
test_pi_unexpected_signaled_exit_notifies_once
test_pi_duplicate_factories_share_one_arm
test_pi_stale_callback_cannot_clear_replacement
test_pi_process_exit_cleanup_stops_arm_child
test_pi_live_acceptance_helper_records_isolated_evidence
test_opencode_primary_watch_plugin_static_wiring
test_opencode_primary_watch_plugin_uses_effective_state_home
test_opencode_primary_watch_plugin_sources_effective_config
test_opencode_primary_watch_plugin_requires_session_lock
test_opencode_watch_arm_coordinator_respects_primary_scope
test_opencode_watch_arm_coordinator_accepts_marked_secondmate
test_opencode_primary_watch_plugin_rearms_after_wake
test_opencode_watch_arm_coordinates_with_turnend_guard
test_opencode_healthy_arm_output_does_not_suppress_guard
