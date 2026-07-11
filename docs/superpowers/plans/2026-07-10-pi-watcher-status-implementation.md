# Pi Watcher Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an always-visible, event-driven Pi status that reports only Firstmate watcher supervision lifecycle and clears cleanly on unload.

**Architecture:** Extend the existing process-global, per-`FM_HOME` Pi watcher coordinator with one typed visible state and a set of active status clients.
Coordinator lifecycle events publish through each client's Pi `ctx.ui.setStatus` interface, while generation and shutdown guards prevent old asynchronous callbacks from overwriting current or cleared UI.

**Tech Stack:** TypeScript, Pi extension API `ctx.ui.setStatus(key, text)`, Node.js child-process events, Bash test fixtures, strict `tsc`, `shellcheck`, and an isolated tmux-driven live Pi regression.

## Global Constraints

- The dedicated status key is exactly `firstmate.pi.watcher`.
- The exact visible strings are `Firstmate watcher: offline`, `Firstmate watcher: watching`, `Firstmate watcher: handling wake`, and `Firstmate watcher: attention`.
- The status is visible before the first arm in a real Firstmate primary or secondmate home.
- `offline` means no owned arm exists before first arm or after an intentional normal stop.
- `watching` means the current-generation owned arm child is running and owns native watcher wake delivery.
- `handling wake` begins only after Pi accepts an actionable follow-up and remains until a successful re-arm or final shutdown.
- `attention` covers lock or ownership refusal, external healthy ownership, spawn or child failure, unexplained exit, and follow-up delivery failure.
- Final extension or session shutdown clears the dedicated key rather than publishing `offline`.
- Status updates are driven only by existing coordinator lifecycle events, with no polling loop.
- Intentional stop or reload injects no wake and never publishes transient `attention`.
- Old-generation callbacks cannot deliver a wake, change child ownership, or overwrite current or cleared status.
- No widget, custom footer, generic jobs UI, job list, tmux job manager, Tau feature copy, stall watchdog, GitHub logic, PR logic, CI logic, backlog logic, decision logic, or task-state logic belongs in the extension.
- Future PR and decision UX remains a separate AI-maintained snapshot outside the watcher extension.

---

## File map

- Modify `.pi/extensions/fm-primary-pi-watch.ts` to own the status types, exact key and labels, client projection, transition publication, generation guards, and shutdown clearing.
- Modify `tests/fm-pi-watch-extension.test.sh` to provide the fake Pi status UI and cover every approved state, transition, precedence rule, scope boundary, and non-goal.
- Modify `tests/fm-pi-primary-live-e2e.test.sh` to observe the exact status labels through a clean, isolated real Pi session across load, arm, wake, re-arm, reload, and quit.
- Verify `tests/fm-pi-primary-types.test.sh` unchanged as the installed Pi API signature contract.
- Modify `docs/supervision-protocols/pi.md` only after live verification to record the status lifecycle command and observed result.
- Do not modify `docs/superpowers/specs/2026-07-10-pi-watcher-status-design.md`; it is the approved source of truth.

### Task 1: Lock the status interface and basic state vocabulary with tests

**Files:**
- Modify: `tests/fm-pi-watch-extension.test.sh:1-980`
- Modify: `.pi/extensions/fm-primary-pi-watch.ts:10-180`

**Interfaces:**
- Consumes: Pi's `ctx.ui.setStatus(key: string, text: string | undefined): void` callback supplied on `session_start`.
- Produces: `type WatcherStatus = "offline" | "watching" | "handling wake" | "attention"`.
- Produces: `type StatusUi = { setStatus(key: string, text: string | undefined): void }`.
- Produces: `const FIRSTMATE_PI_WATCHER_STATUS_KEY = "firstmate.pi.watcher" as const`.
- Produces: `const WATCHER_STATUS_TEXT: Record<WatcherStatus, string>` containing all four exact visible labels.
- Produces: `writeClientStatus(client: StatusClient, status: WatcherStatus | undefined): void`.
- Produces: `publishStatus(coordinator: ArmCoordinator, status: WatcherStatus): void`.

- [ ] **Step 1: Add the fake status UI and exact assertion helper**

Add this module body in `install_pi_status_harness()` so every status test records the real Pi signature and compares the approved key and visible text.

```javascript
export const WATCHER_STATUS_KEY = "firstmate.pi.watcher";
export const watcherStatusWrite = (state) => [
  WATCHER_STATUS_KEY,
  state === undefined ? undefined : `Firstmate watcher: ${state}`,
];

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
```

- [ ] **Step 2: Write the failing pre-arm, successful-arm, and duplicate-arm assertions**

Update `test_pi_status_loads_offline_before_arm`, `test_pi_status_successful_arm_watching`, `test_pi_status_duplicate_arm_preserves_watching`, `test_pi_status_duplicate_factory_preserves_active_watching`, `test_pi_status_legacy_coordinator_reload_compatibility`, `test_pi_status_actionable_wake_and_rearm`, `test_pi_status_attention_failures`, `test_pi_status_intentional_stop_offline`, `test_pi_status_reload_and_quit_clear`, `test_pi_status_reload_overlap_preserves_replacement_ownership`, `test_pi_status_stale_generation_cannot_overwrite`, and `test_pi_status_cancelled_start_stays_cleared` to import `watcherStatusWrite` and replace every literal status-key and visible-text pair with that helper.
Use these exact assertions for the pre-arm, successful-arm, and duplicate-arm red test.

```javascript
const { makeStatusHarness, watcherStatusWrite } = await import(
  pathToFileURL(process.env.STATUS_HARNESS).href,
);

await harness.handlers.get("session_start")?.(
  { type: "session_start" },
  harness.ctx,
);
assert.deepEqual(harness.writes, [watcherStatusWrite("offline")]);

await harness.tool().execute("status-first-arm", {}, undefined, undefined, {});
assert.deepEqual(harness.writes.at(-1), watcherStatusWrite("watching"));

const sequenceBeforeDuplicate = coordinator.sequence;
const generationBeforeDuplicate = coordinator.generation;
const writesBeforeDuplicate = harness.writes.length;
await harness.tool().execute("status-duplicate-arm", {}, undefined, undefined, {});
assert.equal(harness.writes.length, writesBeforeDuplicate);
assert.deepEqual(harness.writes.at(-1), watcherStatusWrite("watching"));
assert.equal(coordinator.sequence, sequenceBeforeDuplicate);
assert.equal(coordinator.generation, generationBeforeDuplicate);
```

For the duplicate-factory case, assert that the replacement client immediately receives `watcherStatusWrite("watching")`, that the original client clears only its own status on retirement, and that exactly one arm child exists.

- [ ] **Step 3: Run the focused tests and confirm the approved contract fails before code changes**

Run:

```bash
tests/fm-pi-watch-extension.test.sh
```

Expected: nonzero exit at `test_pi_status_loads_offline_before_arm` or the next status assertion, showing the old key or text differs from `firstmate.pi.watcher` and `Firstmate watcher: offline`.

- [ ] **Step 4: Add the typed status vocabulary and exact key and label map**

Add these definitions beside the existing coordinator types in `.pi/extensions/fm-primary-pi-watch.ts`.

```typescript
type WatcherStatus = "offline" | "watching" | "handling wake" | "attention";
type StatusUi = {
  setStatus(key: string, text: string | undefined): void;
};

type StatusClient = WakeSender & {
  token: symbol;
  ui: StatusUi | null;
  active: boolean;
  sendWake: WakeSender;
};

const FIRSTMATE_PI_WATCHER_STATUS_KEY = "firstmate.pi.watcher" as const;
const WATCHER_STATUS_TEXT: Record<WatcherStatus, string> = {
  offline: "Firstmate watcher: offline",
  watching: "Firstmate watcher: watching",
  "handling wake": "Firstmate watcher: handling wake",
  attention: "Firstmate watcher: attention",
};
```

Keep `StatusClient` callable through its `WakeSender` intersection so a same-process reload remains compatible with a coordinator created by the prior extension generation.

- [ ] **Step 5: Add coordinator state and event-driven status projection**

Add `visibleStatus: WatcherStatus` and `clients: Map<symbol, StatusClient>` to `ArmCoordinator`, initialize `visibleStatus` to `offline`, and normalize an existing same-process coordinator before registering a new client.

```typescript
function writeClientStatus(
  client: StatusClient,
  status: WatcherStatus | undefined,
): void {
  if (!client.active || !client.ui) return;
  client.ui.setStatus(
    FIRSTMATE_PI_WATCHER_STATUS_KEY,
    status === undefined ? undefined : WATCHER_STATUS_TEXT[status],
  );
}

function publishStatus(
  coordinator: ArmCoordinator,
  status: WatcherStatus,
): void {
  if (coordinator.shuttingDown) return;
  coordinator.visibleStatus = status;
  for (const client of coordinator.clients.values()) {
    writeClientStatus(client, status);
  }
}
```

In `session_start`, capture the current client's UI and immediately project the coordinator state.

```typescript
pi.on?.("session_start", (_event, ctx) => {
  client.ui = ctx.ui;
  writeClientStatus(client, coordinator.visibleStatus);
  markLoaded();
});
```

Publish `watching` immediately after the successfully spawned child is installed as `coordinator.current` and the coordinator enters `running`.
Do not publish or increment anything when `startArmOnce()` returns the existing duplicate-arm result.

- [ ] **Step 6: Run the focused suite and strict type contract**

Run:

```bash
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Expected: the status-load, successful-arm, duplicate-arm, duplicate-factory, and legacy reload assertions pass; the complete extension suite exits zero; the type test prints `ok - Pi primary extensions pass strict no-emit typecheck against Pi 0.80.6`.

- [ ] **Step 7: Commit the basic status interface**

```bash
git add .pi/extensions/fm-primary-pi-watch.ts tests/fm-pi-watch-extension.test.sh
git commit -m "feat: expose Pi watcher status"
```

### Task 2: Implement transition precedence, reload ownership, and generation safety

**Files:**
- Modify: `tests/fm-pi-watch-extension.test.sh:340-980`
- Modify: `.pi/extensions/fm-primary-pi-watch.ts:180-620`

**Interfaces:**
- Consumes: `publishStatus(coordinator: ArmCoordinator, status: WatcherStatus): void` from Task 1.
- Consumes: existing `WakeDetails`, `ArmRecord.generation`, `ArmRecord.intentionalStopReason`, `ArmCoordinator.generation`, `ArmCoordinator.current`, `ArmCoordinator.startPromise`, and `ArmCoordinator.shutdownPromise`.
- Produces: `type StopDisposition = "offline" | "clear"`.
- Produces: `stopArm(coordinator: ArmCoordinator, reason: string, disposition?: StopDisposition): Promise<void>`.
- Preserves: `startArm(): Promise<ArmResult>` and the registered command and tool result signatures.

- [ ] **Step 1: Write the failing actionable-wake and failure-transition assertions**

Update `test_pi_status_actionable_wake_and_rearm` to run all four reasons and assert exact status writes after delivery and re-arm.

```javascript
for (const reason of [
  "signal: synthetic wake",
  "stale: synthetic wake",
  "check: synthetic wake",
  "heartbeat: synthetic wake",
]) {
  await harness.tool().execute("status-actionable-arm", {}, undefined, undefined, {});
  for (let i = 0; i < 100 && harness.messages.length === 0; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.equal(harness.messages.length, 1);
  assert.deepEqual(harness.writes.at(-1), watcherStatusWrite("handling wake"));
  await harness.tool().execute("status-rearm", {}, undefined, undefined, {});
  assert.deepEqual(harness.writes.at(-1), watcherStatusWrite("watching"));
}
```

Update `test_pi_status_attention_failures` to cover these exact cases: live other lock owner, unsuccessful lock recovery, spawn `ENOENT`, child `error`, unexplained clean exit, nonzero exit, unexpected signal, external healthy watcher output, and thrown `sendMessage`.
For each case, wait for and assert `watcherStatusWrite("attention")`.
For thrown `sendMessage`, also assert that no `handling wake` write occurred.
For lock and external ownership failures, assert that no second owned arm child was created.

- [ ] **Step 2: Write the failing intentional-stop, reload, and shutdown assertions**

Update `test_pi_status_intentional_stop_offline`, `test_pi_status_reload_and_quit_clear`, `test_pi_status_reload_overlap_preserves_replacement_ownership`, and `test_pi_status_cancelled_start_stays_cleared` with these exact checks.

```javascript
await mod.stopArm(coordinator, "manual-stop", "offline");
assert.equal(record.intentionalStopReason, "manual-stop");
assert.deepEqual(harness.writes.at(-1), watcherStatusWrite("offline"));
assert.equal(harness.writes.some((write) => write[1] === "Firstmate watcher: attention"), false);
assert.equal(harness.messages.length, 0);

const shutdown = Promise.resolve(
  harness.handlers.get("session_shutdown")?.(
    { type: "session_shutdown", reason: "quit" },
    harness.ctx,
  ),
);
assert.deepEqual(harness.writes.at(-1), watcherStatusWrite(undefined));
const writesAfterClear = harness.writes.length;
await shutdown;
await new Promise((resolve) => setTimeout(resolve, 80));
assert.equal(harness.writes.length, writesAfterClear);
```

For replacement-before-retirement, assert that the new client projects the coordinator's `watching` state, the old client clears, the shared child remains current, and no wake is injected.
For retirement-before-replacement, assert that shutdown clears and settles the old child, then the replacement starts at `offline` and can arm to `watching`.
For a start waiting on lock acquisition, assert that shutdown clears before releasing the lock, the late start returns `ok: false`, no arm is spawned, no message is sent, and no later status write occurs.

- [ ] **Step 3: Write the failing stale-generation assertions**

Update `test_pi_status_stale_generation_cannot_overwrite` so callbacks from the replaced arm are emitted over every later state.

```javascript
const assertStalePreserves = async (expected) => {
  const writes = harness.writes.length;
  const messages = harness.messages.length;
  old.child.emit("error", new Error(`stale over ${String(expected)}`));
  old.child.emit("close", 7, null);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(harness.writes.length, writes);
  assert.equal(harness.messages.length, messages);
  assert.deepEqual(harness.writes.at(-1), watcherStatusWrite(expected));
};

await assertStalePreserves("watching");
await assertStalePreserves("handling wake");
await assertStalePreserves("attention");
await assertStalePreserves(undefined);
```

- [ ] **Step 4: Add the static scope and no-polling test**

Keep `test_pi_status_absent_in_task_worktree` asserting zero registrations and zero status writes in an ordinary linked task worktree.
Update `test_pi_status_static_non_goals` to enforce the approved key and exclusions.

```bash
assert_contains "$text" '"firstmate.pi.watcher"' "Pi watcher status key drifted"
for forbidden in \
  'setInterval(' 'setWidget(' 'setFooter(' 'gh pr' 'backlog.md' \
  'fm-pr-' 'tmux job' 'stall watchdog'; do
  assert_not_contains "$text" "$forbidden" \
    "Pi watcher status introduced forbidden surface: $forbidden"
done
```

Permit only the existing bounded process-group cleanup `setTimeout` inside `stopsWithin()`.
Assert that its block has a deadline and contains no `publishStatus`, `writeClientStatus`, or `visibleStatus` reference.

- [ ] **Step 5: Run the lifecycle tests and confirm they fail before transition code changes**

Run:

```bash
tests/fm-pi-watch-extension.test.sh
```

Expected: nonzero exit on the first not-yet-implemented exact label or lifecycle transition, with no unrelated test failure accepted as the TDD red state.

- [ ] **Step 6: Publish actionable and failure outcomes with generation guards**

In `settleArm()`, retain the existing exactly-once settlement guard, clear `coordinator.current` only when both record identity and generation match, and return before any outcome processing for a stale record, shutdown, or intentional stop.
Use this status ordering around the existing wake delivery.

```typescript
const ownsGeneration =
  coordinator.current === record &&
  coordinator.generation === record.generation;
if (ownsGeneration) {
  coordinator.current = null;
  coordinator.state = "idle";
}
if (
  !ownsGeneration ||
  coordinator.shuttingDown ||
  record.intentionalStopReason
) {
  return;
}

if (kind === "failure") {
  publishStatus(coordinator, "attention");
}

void activeClient.sendWake(message, details).then(() => {
  if (
    kind === "actionable" &&
    coordinator.generation === record.generation &&
    !coordinator.shuttingDown &&
    activeClient.active &&
    coordinator.clients.get(activeClient.token) === activeClient
  ) {
    publishStatus(coordinator, "handling wake");
  }
}).catch(() => {
  if (
    coordinator.generation === record.generation &&
    !coordinator.shuttingDown &&
    activeClient.active &&
    coordinator.clients.get(activeClient.token) === activeClient
  ) {
    publishStatus(coordinator, "attention");
  }
});
```

A clean zero exit without an actionable line must use the existing unexpected-exit failure path and publish `attention`.
The external `watcher: healthy` arm result remains a failure because the extension does not own that watcher's wake delivery.

- [ ] **Step 7: Publish ownership refusal and preserve duplicate ownership**

In `startArmOnce()`, publish `attention` only after lock acquisition has settled and ownership is still not this Pi session.
Return an existing current child as healthy without changing generation, sequence, child ownership, or visible status.
After a successful new child installation, publish `watching`, which is the only ordinary transition that clears `handling wake` or `attention`.

```typescript
if (lockOwnership() !== "owned") {
  publishStatus(coordinator, "attention");
  return {
    ok: false,
    message: "watcher: read-only - session lock is held by another firstmate session",
  };
}
if (coordinator.current) {
  return {
    ok: true,
    message: "watcher: healthy - Pi extension already has an arm child",
  };
}

coordinator.current = record;
coordinator.state = "running";
publishStatus(coordinator, "watching");
```

- [ ] **Step 8: Add intentional stop disposition and shutdown-first precedence**

Use the exact disposition type and exported signature.

```typescript
type StopDisposition = "offline" | "clear";

export async function stopArm(
  coordinator: ArmCoordinator,
  reason: string,
  disposition: StopDisposition = "clear",
): Promise<void> {
  const record = coordinator.current;
  if (record) {
    await stopArmRecord(coordinator, record, reason, disposition);
  } else if (disposition === "offline" && coordinator.clients.size > 0) {
    publishStatus(coordinator, "offline");
  }
}
```

`stopArmRecord()` must set `intentionalStopReason` before sending `SIGTERM`.
After bounded settlement, publish `offline` only for disposition `offline`, while at least one client remains, and while shutdown is false.

In `shutdownClient()`, perform operations in this order: clear the retiring client's key, mark it inactive, delete it, return without stopping if another client is active, otherwise set shutdown and cancellation flags, mark the record intentional, increment generation, await any pending start, stop with disposition `clear`, and remove the process-exit listener only if no replacement registered.
A replacement registering during old cleanup waits for `shutdownPromise`, resets shutdown flags when it owns an active client, projects the retained coordinator status, and cannot be cleared by the old shutdown token.

- [ ] **Step 9: Run the complete extension, type, and shell checks**

Run:

```bash
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
shellcheck tests/fm-pi-watch-extension.test.sh
```

Expected: exit zero from all three commands; the extension suite prints pass lines for offline, watching, actionable wake, attention failures, intentional stop, both reload orderings, duplicate ownership, stale generation, cancelled start, task-worktree absence, and static non-goals; `shellcheck` prints no diagnostics.

- [ ] **Step 10: Commit lifecycle precedence and safety**

```bash
git add .pi/extensions/fm-primary-pi-watch.ts tests/fm-pi-watch-extension.test.sh
git commit -m "test: cover Pi watcher status lifecycle"
```

### Task 3: Prove exact labels and cleanup in a clean live Pi session

**Files:**
- Modify: `tests/fm-pi-primary-live-e2e.test.sh:59-95,270-395`
- Verify: `tests/fm-pi-primary-types.test.sh`
- Modify: `docs/supervision-protocols/pi.md`

**Interfaces:**
- Consumes: the exact visible strings published through `ctx.ui.setStatus`.
- Consumes: the existing `FM_PI_LIVE_E2E`, `FM_PI_LIVE_AUTH_FILE`, `FM_PI_LIVE_ROLE`, `FM_PI_LIVE_PROVIDER`, `FM_PI_LIVE_MODEL`, and `FM_PI_LIVE_THINKING` test inputs.
- Produces: `wait_for_status(state: string, attempts?: number): 0 | 1` matching `Firstmate watcher: ${state}`.
- Produces: `wait_for_status_absent(attempts?: number): 0 | 1` rejecting all four exact labels.

- [ ] **Step 1: Update the live status matchers and final success line**

Replace the status helpers with exact prefixed matching.

```bash
watcher_status_text() {
  printf 'Firstmate watcher: %s\n' "$1"
}

wait_for_status() {
  local state=$1 attempts=${2:-120} i=0 expected
  expected=$(watcher_status_text "$state")
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
    if ! current_status_lines | grep -Eq '^Firstmate watcher: (offline|watching|handling wake|attention)$'; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  capture_current >&2
  return 1
}
```

Set the final success line to:

```bash
printf 'ok - Pi %s %s watcher status moved offline -> watching -> handling wake -> watching, reloaded to offline, and cleared with clean process shutdown\n' "$PI_VERSION" "$ROLE"
```

- [ ] **Step 2: Keep the live transition sequence explicit**

The live body must assert this exact event order without automatically re-arming inside the wake-handling prompt.

```bash
wait_for_status offline || fail "fresh watcher extension did not show offline"

send_prompt 'Use fm_watch_arm_pi exactly once to start supervision. Never use bash to arm supervision. Reply exactly ARMED. After any FIRSTMATE WATCHER WAKE, run bin/fm-wake-drain.sh, read the signaled status, do not re-arm, and finish exactly WAKE-HANDLED.'
wait_for_text "watcher: started Pi extension arm child 1" 180 || fail "native Pi tool did not arm supervision"
wait_for_status watching || fail "owned arm did not show watching"

printf 'done: pi live e2e watcher fire\n' > "$PROJECT/state/pi-e2e.status"
wait_for_status "handling wake" 240 || fail "delivered actionable wake did not show handling wake"
wait_for_text_count_after "WAKE-HANDLED" "$wake_handled_before" 180 || fail "Pi did not settle after handling the watcher wake"

send_prompt 'Use fm_watch_arm_pi exactly once to resume supervision after the handled wake. Do not use bash. Reply exactly REARMED.'
wait_for_text "watcher: started Pi extension arm child 2" 180 || fail "separate native re-arm did not start a new coordinator generation"
wait_for_status watching 180 || fail "successful re-arm did not restore watching"
```

Then invoke `/reload`, assert the old key becomes absent before reload finishes, assert the replacement displays `offline`, assert the old arm and watcher processes are dead, and assert no failure wake or exit-143 text appeared.
After a post-reload arm reaches `watching`, invoke `/quit`, assert status absence, Pi exit zero, and no surviving Pi, arm, watcher, or lab-owned descendant process.

- [ ] **Step 3: Run static checks before the live test**

Run:

```bash
shellcheck tests/fm-pi-watch-extension.test.sh tests/fm-pi-primary-live-e2e.test.sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Expected: `shellcheck` prints no diagnostics; both test scripts exit zero; the type test reports strict no-emit success against Pi 0.80.6.

- [ ] **Step 4: Run the clean isolated live Pi verification as primary**

Run:

```bash
FM_PI_LIVE_E2E=1 \
FM_PI_LIVE_AUTH_FILE="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/auth.json" \
FM_PI_LIVE_ROLE=primary \
tests/fm-pi-primary-live-e2e.test.sh
```

Expected final lines:

The penultimate line must match this exact regular expression.

```text
^evidence - role=primary candidate_hash=sha256:[0-9a-f]{64} candidate_pid=[1-9][0-9]* lock_pid=[1-9][0-9]* arm_pgid=[1-9][0-9]* watcher_pid=[1-9][0-9]* old_pi_pid=[1-9][0-9]* all_clean=true$
```

The final line must be exactly:

```text
ok - Pi 0.80.6 primary watcher status moved offline -> watching -> handling wake -> watching, reloaded to offline, and cleared with clean process shutdown
```

The regular-expression line validates runtime evidence fields rather than values that should be copied into source.
The command must run with the script-created empty `PI_CODING_AGENT_DIR`, dedicated tmux socket, temporary project path, and owned cleanup sentinel.
Any trust prompt after the approved detached launch, duplicate extension registration, foreground watcher arm, false failure on reload, stale status after quit, or surviving lab process is a failure.

- [ ] **Step 5: Run the same clean live verification as a secondmate home**

Run:

```bash
FM_PI_LIVE_E2E=1 \
FM_PI_LIVE_AUTH_FILE="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/auth.json" \
FM_PI_LIVE_ROLE=secondmate \
tests/fm-pi-primary-live-e2e.test.sh
```

Expected final status line:

```text
ok - Pi 0.80.6 secondmate watcher status moved offline -> watching -> handling wake -> watching, reloaded to offline, and cleared with clean process shutdown
```

- [ ] **Step 6: Record the empirical result in the Pi supervision protocol**

Append a dated paragraph to `docs/supervision-protocols/pi.md` with the two exact commands from Steps 4 and 5 and their exact `ok -` lines.
State that the visible lifecycle was `offline -> watching -> handling wake -> watching`, reload cleared then restored `offline`, quit cleared the key, and all recorded Pi, arm, and watcher processes exited.
Do not add implementation mechanics already owned by the extension or copy any GitHub, backlog, PR, decision, or generic jobs UI discussion into that protocol.

- [ ] **Step 7: Run the final verification set**

Run:

```bash
git diff --check
shellcheck tests/fm-pi-watch-extension.test.sh tests/fm-pi-primary-live-e2e.test.sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Expected: every command exits zero, `git diff --check` and `shellcheck` print no diagnostics, the extension suite reports every status lifecycle case as passing, and strict TypeScript no-emit passes against the installed Pi 0.80.6 API.

- [ ] **Step 8: Review scope and commit the live proof**

Run:

```bash
git diff -- .pi/extensions/fm-primary-pi-watch.ts tests/fm-pi-watch-extension.test.sh tests/fm-pi-primary-live-e2e.test.sh tests/fm-pi-primary-types.test.sh docs/supervision-protocols/pi.md
grep -En 'setWidget|setFooter|setInterval|gh pr|backlog\.md|fm-pr-|tmux job|stall watchdog' .pi/extensions/fm-primary-pi-watch.ts
```

Expected: the diff contains only watcher status lifecycle code, focused tests, live verification, and empirical Pi protocol evidence; `tests/fm-pi-primary-types.test.sh` remains unchanged; the grep prints no matches.

```bash
git add .pi/extensions/fm-primary-pi-watch.ts tests/fm-pi-watch-extension.test.sh tests/fm-pi-primary-live-e2e.test.sh docs/supervision-protocols/pi.md
git commit -m "test: verify Pi watcher status live"
```

## Final acceptance checklist

- [ ] The dedicated key is `firstmate.pi.watcher` everywhere.
- [ ] Every visible label includes the exact `Firstmate watcher: ` prefix.
- [ ] A real Firstmate home shows `offline` before arm.
- [ ] Owned arm, duplicate arm, actionable delivery, successful re-arm, all attention outcomes, and intentional stop match the approved transition table.
- [ ] Replacement-before-retirement and retirement-before-replacement reload orderings are tested.
- [ ] Final shutdown clears before asynchronous settlement and cannot be overwritten.
- [ ] Old-generation close, error, delivery, and stop completions cannot overwrite current or cleared status.
- [ ] Ordinary task worktrees do not register or show watcher status.
- [ ] Status updates contain no polling, widget, custom footer, generic jobs, stall watchdog, GitHub, PR, CI, backlog, decision, or task-state behavior.
- [ ] Strict TypeScript, shell checks, deterministic extension tests, and clean primary and secondmate live Pi runs all pass.
