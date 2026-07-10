# Pi Watcher Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the native Pi watcher coordinator lifecycle through Pi's existing extension status API with the dedicated `firstmate-pi-watcher` key.

**Architecture:** Extend the candidate's process-wide coordinator for each resolved `FM_HOME` with one event-driven visible state and active UI clients.
The coordinator publishes only current-generation lifecycle events, while each extension client owns clearing its status entry during unload.
The existing child, lock, generation, startup-cancellation, and intentional-stop paths remain authoritative and gain status writes at their settled transition points.

**Tech Stack:** TypeScript, Pi 0.80.6 `ExtensionAPI`, Node.js `child_process`, Bash test harnesses with inline Node ESM fixtures, tmux for the opt-in live Pi regression.

## Global Constraints

- The exclusive Pi `setStatus` key is exactly `firstmate-pi-watcher`.
- The only displayed values are exactly `offline`, `watching`, `handling wake`, and `attention`.
- Clearing uses `ctx.ui.setStatus("firstmate-pi-watcher", undefined)` and is not a fifth displayed state.
- A real primary or marked secondmate supervising home publishes `offline` on `session_start` before any arm request.
- An ordinary linked task worktree performs no status write and leaves the key absent.
- Status changes are coordinator-event driven only.
- No status polling, filesystem polling, `setInterval`, or status-refresh `setTimeout` is allowed.
- A one-shot bounded child-cleanup deadline may use `setTimeout`; it must not read or refresh status.
- Pi wake injection uses `pi.sendMessage(...)` with `customType: "firstmate-watcher-wake"`, `deliverAs: "followUp"`, and `triggerTurn: true`.
- The watcher extension must not call `pi.sendUserMessage(...)`.
- Pi 0.80.6 declares `ExtensionAPI.sendMessage(...)` as returning `void`, so delivery acceptance means the call returned normally and delivery failure means it threw synchronously.
- Successful installation of a current owned arm is the only ordinary transition to `watching`.
- Successful delivery of an actionable current-generation wake is the only transition to `handling wake`.
- Shutdown clear has highest precedence, followed by current-record/current-generation ownership, intentional-stop classification, actionable classification, and generic failure classification.
- Keep PR, CI, backlog, task, and decision UX out of this extension.
- Keep widgets, custom footers, polling, generic jobs UI, tmux job management, and stall watchdogs out of scope.
- Do not add or change a product-status snapshot.

**Design authority:** `docs/superpowers/specs/2026-07-10-pi-watcher-status-design.md`.

---

## File and interface map

| File | Responsibility in this implementation |
| --- | --- |
| `.pi/extensions/fm-primary-pi-watch.ts` | Add status constants, status clients, coordinator state, exact lifecycle writes, exact wake API, and shutdown clearing. |
| `tests/fm-pi-watch-extension.test.sh` | Extend the existing candidate fixture with the 11 deterministic status-contract tests and static non-goal assertions. |
| `tests/fm-pi-primary-types.test.sh` | Verify the changed extension against the installed Pi 0.80.6 declarations without emitting JavaScript. |
| `tests/fm-pi-primary-live-e2e.test.sh` | Observe the clean live sequence `offline` -> `watching` -> `handling wake` -> `watching`, reload to a fresh `offline`, and clear/cleanup on quit. |

The implementation extends these candidate interfaces rather than creating a second coordinator:

```typescript
type WatcherStatus = "offline" | "watching" | "handling wake" | "attention";

type StatusUi = {
  setStatus(key: string, text: string | undefined): void;
};

type StatusClient = {
  token: symbol;
  ui: StatusUi | null;
  active: boolean;
  sendWake: WakeSender;
};

type StopDisposition = "offline" | "clear";

type ArmRecord = {
  child: ChildProcess;
  generation: number;
  intentionalStopReason: string;
  settled: boolean;
  completion: Promise<void>;
  resolveCompletion: () => void;
  stdout: string;
  stderr: string;
  stdoutPending: string;
  stderrPending: string;
  stdoutTruncated: boolean;
  stderrTruncated: boolean;
  actionable: string;
  failureHint: string;
};

type ArmCoordinator = {
  current: ArmRecord | null;
  lastCompleted: CompletedCapture | null;
  generation: number;
  sequence: number;
  state: CoordinatorState;
  visibleStatus: WatcherStatus;
  startPromise: Promise<ArmResult> | null;
  startCancelled: boolean;
  shuttingDown: boolean;
  clients: Map<symbol, StatusClient>;
  exitListener?: () => void;
};
```

The process-global `Map<string, ArmCoordinator>` remains keyed by the resolved `fmHome` path.
No file, lock, process, or timer is consulted to infer status after a lifecycle event.

---

### Task 1: Add the status contract, first-load state, successful start, and duplicate behavior

**Files:**

- Modify: `tests/fm-pi-watch-extension.test.sh`.
- Modify: `.pi/extensions/fm-primary-pi-watch.ts`.

**Interfaces:**

- Produces `FIRSTMATE_PI_WATCHER_STATUS_KEY: "firstmate-pi-watcher"`.
- Produces `WATCHER_STATUS_TEXT: Record<WatcherStatus, WatcherStatus>`.
- Produces `writeClientStatus(client, status)` for exactly one active client.
- Produces `publishStatus(coordinator, status)` for all active clients of the resolved home.
- Extends `ArmCoordinator` with `visibleStatus`, `shuttingDown`, and `Map<symbol, StatusClient>`.
- Preserves the candidate's `startArm(): Promise<ArmResult>` and shared per-home coordinator.

- [ ] **Step 1: Add the shared fake status recorder and failing tests 1, 2, and 7**

Add this shell helper beside `install_pi_watch_extension_fixture` in `tests/fm-pi-watch-extension.test.sh` so each fixture gets an importable Node module:

```bash
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
```

Add these named test functions and invoke them in the test list at the bottom of the file:

```bash
test_pi_status_loads_offline_before_arm
test_pi_status_successful_arm_watching
test_pi_status_duplicate_arm_preserves_watching
```

Each inline Node fixture must call the registered `session_start` handler before arming.
Each inline fixture must import `assert` and the helper explicitly:

```javascript
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const { makeStatusHarness } = await import(
  pathToFileURL(process.env.STATUS_HARNESS).href,
);
```

Pass `STATUS_HARNESS="$repo/status-harness.mjs"` in that fixture's Node environment.

Use these exact assertions:

```javascript
await harness.handlers.get("session_start")?.({ type: "session_start" }, harness.ctx);
assert.deepEqual(harness.writes, [["firstmate-pi-watcher", "offline"]]);

await harness.tool().execute("status-first-arm", {}, undefined, undefined, {});
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "watching"]);

const writesBeforeDuplicate = harness.writes.length;
await harness.tool().execute("status-duplicate-arm", {}, undefined, undefined, {});
assert.equal(readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length, 1);
assert.equal(harness.writes.length, writesBeforeDuplicate);
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "watching"]);
```

The controlled arm script must remain alive until shutdown:

```bash
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
trap 'exit 0' TERM
while :; do sleep 0.05; done
```

- [ ] **Step 2: Run the new tests and verify the expected red state**

Run:

```bash
tests/fm-pi-watch-extension.test.sh
```

Expected: nonzero exit from `test_pi_status_loads_offline_before_arm` because the candidate has not called `setStatus`.

- [ ] **Step 3: Add the exact constants and coordinator fields**

Add near the candidate coordinator types:

```typescript
const FIRSTMATE_PI_WATCHER_STATUS_KEY = "firstmate-pi-watcher" as const;

type WatcherStatus = "offline" | "watching" | "handling wake" | "attention";
type StatusUi = { setStatus(key: string, text: string | undefined): void };
type StatusClient = { token: symbol; ui: StatusUi | null; active: boolean };

const WATCHER_STATUS_TEXT: Record<WatcherStatus, WatcherStatus> = {
  offline: "offline",
  watching: "watching",
  "handling wake": "handling wake",
  attention: "attention",
};
```

Initialize every fresh coordinator with:

```typescript
visibleStatus: "offline",
shuttingDown: false,
clients: new Map<symbol, StatusClient>(),
```

- [ ] **Step 4: Add active-client projection without polling**

Add these helpers:

```typescript
function writeClientStatus(client: StatusClient, status: WatcherStatus | undefined): void {
  if (!client.active || !client.ui) return;
  client.ui.setStatus(
    FIRSTMATE_PI_WATCHER_STATUS_KEY,
    status === undefined ? undefined : WATCHER_STATUS_TEXT[status],
  );
}

function publishStatus(coordinator: ArmCoordinator, status: WatcherStatus): void {
  if (coordinator.shuttingDown) return;
  coordinator.visibleStatus = status;
  for (const client of coordinator.clients.values()) writeClientStatus(client, status);
}
```

Create one client per extension factory and attach its UI on `session_start`:

```typescript
const client: StatusClient = {
  token: Symbol("pi-watch-extension-client"),
  ui: null,
  active: true,
};
coordinator.clients.set(client.token, client);

pi.on?.("session_start", (_event, ctx) => {
  client.ui = ctx.ui;
  writeClientStatus(client, coordinator.visibleStatus);
  markLoaded();
});
```

The existing early `if (!supervisingHome()) return;` remains before coordinator and client creation.

- [ ] **Step 5: Publish `watching` only after the current generation is installed**

In `startArmOnce`, publish after `coordinator.current = record` and `coordinator.state = "running"`:

```typescript
coordinator.current = record;
coordinator.state = "running";
publishStatus(coordinator, "watching");
```

Leave the duplicate branch free of writes:

```typescript
if (coordinator.current) {
  return { ok: true, message: "watcher: healthy - Pi extension already has an arm child" };
}
```

This preserves `watching`, starts no child, and does not increment `sequence` or `generation`.

- [ ] **Step 6: Run the status tests and existing extension regression**

Run:

```bash
tests/fm-pi-watch-extension.test.sh
```

Expected: the new offline, successful-arm, and duplicate-arm tests print `ok -` lines, and the full script exits 0.

- [ ] **Step 7: Commit the first independently testable slice**

```bash
git add .pi/extensions/fm-primary-pi-watch.ts tests/fm-pi-watch-extension.test.sh
git commit -m "feat(pi): publish watcher startup status"
```

---

### Task 2: Publish actionable and failure outcomes through the exact Pi wake API

**Files:**

- Modify: `tests/fm-pi-watch-extension.test.sh`.
- Modify: `.pi/extensions/fm-primary-pi-watch.ts`.

**Interfaces:**

- Preserves `WakeSender`, `WakeDetails`, and each active client's current `sendWake` closure; `ArmRecord` never owns a Pi runtime closure.
- Preserves `sendWake(message, details): Promise<void>` using the exact Pi custom-message contract and structured bounded-output metadata.
- Extends `settleArm(coordinator, record, code, signal, error?)` without replacing incremental `captureOutput`, `record.actionable`, `failureLine(record, ...)`, or exactly-once settlement.
- Preserves all existing wake text after the `FIRSTMATE WATCHER WAKE:` prefix.

- [ ] **Step 1: Add failing tests 3 and 4 before changing production code**

Add and invoke:

```bash
test_pi_status_actionable_wake_and_rearm
test_pi_status_attention_failures
```

The actionable test must run one case for each recognized reason prefix:

```text
signal: synthetic wake
stale: synthetic wake
check: synthetic wake
heartbeat: synthetic wake
```

For each case, assert the exact custom message and options:

```javascript
assert.equal(harness.messages.length, 1);
assert.equal(harness.messages[0].message.customType, "firstmate-watcher-wake");
assert.equal(harness.messages[0].message.display, true);
assert.match(harness.messages[0].message.content, /^FIRSTMATE WATCHER WAKE:/);
assert.deepEqual(harness.messages[0].options, {
  deliverAs: "followUp",
  triggerTurn: true,
});
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "handling wake"]);
```

After a second controlled arm succeeds, assert the final write is `watching`.

The attention test must table-drive these exact outcomes:

- A live other lock owner refuses startup and spawns no arm.
- Lock recovery returns without ownership and spawns no arm.
- The arm subprocess emits `ENOENT` before a usable child starts because the fixture launches Node by absolute path with a `PATH` that contains no `bash`.
- The current child emits `error`.
- The current child exits cleanly without an actionable or recognized failure line.
- The current child exits nonzero without an actionable line.
- The current child exits from an unexpected signal.
- The arm reports `watcher: healthy ...` from external ownership.
- `pi.sendMessage(...)` throws while delivering an actionable wake.

Induce the arm-process `ENOENT` without changing production code:

```bash
node_bin=$(command -v node)
empty_path="$repo/empty-path"
mkdir -p "$empty_path"
PATH="$empty_path" "$node_bin" --input-type=module
```

Write the owned `.lock` before import so `lockOwnership()` does not need an external `ps` lookup in that fixture.

Each case must end with exactly:

```javascript
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "attention"]);
```

The actionable-delivery throw must never write `handling wake`.

- [ ] **Step 2: Run the suite and verify the expected red state**

Run:

```bash
tests/fm-pi-watch-extension.test.sh
```

Expected: nonzero exit because the candidate still calls the user-message API and does not publish settled actionable or failure status.

- [ ] **Step 3: Preserve the exact custom-message wake API while attaching status to the current client**

Keep the candidate helper's existing signature and structured details:

```typescript
async function sendWake(message: string, details: WakeDetails): Promise<void> {
  pi.sendMessage(
    {
      customType: "firstmate-watcher-wake",
      content: `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.`,
      display: true,
      details,
    },
    { deliverAs: "followUp", triggerTurn: true },
  );
}
```

Store that closure on the active `StatusClient`, not on `ArmRecord`.
Keep every fixture on fake `sendMessage`, and keep `test_tracked_extension_present_and_self_hashing` requiring `sendMessage`, `firstmate-watcher-wake`, `deliverAs: "followUp"`, and `triggerTurn: true` while rejecting the old API name.

- [ ] **Step 4: Extend the current bounded, exactly-once `settleArm` precedence**

Do not replace the candidate implementation with whole-buffer rescanning or record-owned delivery.
Keep `record.settled` as the sole completion gate, call `inspectOutputLine` for the bounded pending fragments, retain the current-generation identity check, save only the bounded `CompletedCapture`, and classify from `record.actionable` or `failureLine(record, code, signal)`.
Build the existing `WakeDetails`, then select the newest active client:

```typescript
const activeClient = [...coordinator.clients.values()].at(-1);
if (!activeClient || !activeClient.active) return;

const delivery = activeClient.sendWake(message, details);
void delivery.then(() => {
  if (
    kind === "actionable" &&
    coordinator.generation === record.generation &&
    !coordinator.shuttingDown &&
    activeClient.active
  ) {
    publishStatus(coordinator, "handling wake");
  }
}).catch(() => {
  if (coordinator.generation === record.generation && !coordinator.shuttingDown) {
    publishStatus(coordinator, "attention");
  }
});
```

Publish `attention` synchronously for every generic failure before attempting its wake delivery.
An unexplained clean exit remains a synthesized failure wake and `attention`; actionable classification remains ahead of generic failure classification.
Never restore whole-buffer actionable-line scanning across `record.stdout` and `record.stderr`, because incremental capture already handles split chunks while keeping memory bounded.

- [ ] **Step 5: Publish startup and ownership failures before returning**

After lock recovery, use:

```typescript
if (lockOwnership() !== "owned") {
  publishStatus(coordinator, "attention");
  return {
    ok: false,
    message: "watcher: read-only - session lock is held by another firstmate session",
  };
}
```

The existing child `error` handler owns process-start errors such as `ENOENT` and routes them through `settleArm`.
The existing close-signal, nonzero-exit, and external-healthy paths also continue through `settleArm`.

- [ ] **Step 6: Run the deterministic suite and strict type contract**

Run:

```bash
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Expected: all extension tests exit 0, and the type test prints `ok - Pi primary watcher extension passes strict no-emit typecheck against Pi 0.80.6`.

- [ ] **Step 7: Commit the outcome slice**

```bash
git add .pi/extensions/fm-primary-pi-watch.ts tests/fm-pi-watch-extension.test.sh
git commit -m "feat(pi): publish watcher outcome status"
```

---

### Task 3: Make intentional stop, reload, quit, cancellation, and stale generations status-safe

**Files:**

- Modify: `tests/fm-pi-watch-extension.test.sh`.
- Modify: `.pi/extensions/fm-primary-pi-watch.ts`.

**Interfaces:**

- Extends the existing bounded `stopArm(coordinator, reason): Promise<void>` with a status disposition without replacing `signalArm`, `settlesWithin`, `STOP_GRACE_MS`, or `STOP_KILL_GRACE_MS`.
- Produces `shutdownClient(reason): Promise<void>` for last-client invalidation, clear, cancellation, bounded process-group settlement, and listener removal.
- Keeps the existing `startPromise` cancellation and monotonic generation contracts.
- Keeps the per-home coordinator across reload so sequence/generation ownership remains monotonic; a replacement client explicitly resets shutdown state and publishes fresh `offline`.

- [ ] **Step 1: Add failing tests 5, 6, 8, and 9**

Add and invoke:

```bash
test_pi_status_intentional_stop_offline
test_pi_status_reload_and_quit_clear
test_pi_status_stale_generation_cannot_overwrite
test_pi_status_cancelled_start_stays_cleared
```

For the normal intentional-stop test, import the named `stopArm` helper and instrument the existing `signalArm` path (or observe the detached process group) before calling it:

```javascript
await mod.stopArm(coordinator, "manual-stop", "offline");
if (record.intentionalStopReason !== "manual-stop") {
  throw new Error("intentional stop reason was not installed before process-group signaling");
}
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", "offline"]);
assert.equal(harness.writes.some(([, value]) => value === "attention"), false);
assert.equal(harness.messages.length, 0);
```

For reload and quit, assert this exact write sequence around each old client shutdown:

```javascript
assert.deepEqual(harness.writes.at(-1), ["firstmate-pi-watcher", undefined]);
const writesAfterClear = harness.writes.length;
await new Promise((resolve) => setTimeout(resolve, 80));
assert.equal(harness.writes.length, writesAfterClear);
```

After the reload shutdown has settled, instantiate the extension again, call its replacement `session_start`, and assert its first write is:

```javascript
["firstmate-pi-watcher", "offline"]
```

The stale-generation test must create a replacement arm, then manually emit old-generation `error` and `close` events.
It must assert no extra wake and no write over each of `watching`, `handling wake`, `attention`, and a cleared key.

Extend the existing delayed-lock test for cancelled pending startup with status assertions.
The last-client shutdown must write `undefined` before the delayed lock claimant is released, and the eventual cancelled start must add no later status write.

- [ ] **Step 2: Run the suite and verify the expected red state**

Run:

```bash
tests/fm-pi-watch-extension.test.sh
```

Expected: nonzero exit because the candidate does not clear the key, export the normal stop helper, or create fresh status state after reload.

- [ ] **Step 3: Extend intentional-stop settlement without weakening process cleanup**

Add the status disposition to the existing helper, but preserve its bounded detached-process-group algorithm exactly:

```typescript
export async function stopArm(
  coordinator: ArmCoordinator,
  reason: string,
  disposition: StopDisposition = "clear",
): Promise<void> {
  const record = coordinator.current;
  if (!record) {
    if (disposition === "offline" && coordinator.clients.size > 0) {
      publishStatus(coordinator, "offline");
    }
    return;
  }

  if (!record.intentionalStopReason) record.intentionalStopReason = reason;
  if (coordinator.current === record) coordinator.state = "stopping";
  signalArm(record, "SIGTERM");
  if (!(await settlesWithin(record, STOP_GRACE_MS))) {
    signalArm(record, "SIGKILL");
    if (!(await settlesWithin(record, STOP_KILL_GRACE_MS))) {
      settleArm(coordinator, record, null, "SIGKILL");
    }
  }

  if (
    disposition === "offline" &&
    !coordinator.shuttingDown &&
    coordinator.clients.size > 0
  ) {
    publishStatus(coordinator, "offline");
  }
}
```

The status slice adds no polling or status timer.
The existing one-shot TERM and KILL deadlines remain cleanup mechanics only; never replace them with an unbounded `await record.completion` or direct-child-only `record.child.kill(...)`.

- [ ] **Step 4: Clear before awaiting last-client shutdown**

Implement the last-client path in this order:

```typescript
async function shutdownClient(reason: string): Promise<void> {
  if (!client.active) return;
  writeClientStatus(client, undefined);
  client.active = false;
  coordinator.clients.delete(client.token);
  if (coordinator.clients.size > 0) return;

  coordinator.shuttingDown = true;
  coordinator.startCancelled = true;
  const record = coordinator.current;
  if (record && !record.intentionalStopReason) record.intentionalStopReason = reason;
  coordinator.generation += 1;

  const pendingStart = coordinator.startPromise;
  if (pendingStart) await pendingStart.catch(() => undefined);
  await stopArm(coordinator, reason, "clear");

  if (coordinator.exitListener) {
    process.off("exit", coordinator.exitListener);
    coordinator.exitListener = undefined;
  }
}
```

Wire `session_shutdown` to `await shutdownClient(event.reason || "session-shutdown")`.
A replacement factory reuses the coordinator, installs only its new client closure, resets `shuttingDown`/`startCancelled`, and publishes fresh `offline`; no stale Pi closure survives in `clients`.
Make the process-exit listener perform the synchronous prefix of the same ordering while preserving full-group cleanup:

```typescript
const cleanupOnProcessExit = () => {
  for (const activeClient of coordinator.clients.values()) {
    writeClientStatus(activeClient, undefined);
    activeClient.active = false;
  }
  coordinator.clients.clear();
  coordinator.shuttingDown = true;
  coordinator.startCancelled = true;
  coordinator.generation += 1;
  stopArmOnProcessExit(coordinator);
};
```

`stopArmOnProcessExit` remains the current detached-group TERM-then-KILL fallback; never replace it with direct PID signaling.

- [ ] **Step 5: Prevent pending startup from restoring status**

Keep the post-lock check before `spawn` and extend it to shutdown:

```typescript
if (
  coordinator.startCancelled ||
  coordinator.shuttingDown ||
  coordinator.clients.size === 0
) {
  return { ok: false, message: "watcher: not started - Pi extension session shut down" };
}
```

The `startPromise.finally(...)` block may restore internal `idle` state, but it must not publish a visible state.
Every status write after a child callback must still pass current-generation and `!shuttingDown` checks.
While the lock claim is pending, test 9 must assert the last displayed value remains the pre-start value until shutdown clears it.

- [ ] **Step 6: Run the shutdown and generation regression**

Run:

```bash
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Expected: all four new lifecycle tests pass, existing child-cleanup and duplicate-factory tests remain green, and strict typecheck exits 0.

- [ ] **Step 7: Commit the lifecycle slice**

```bash
git add .pi/extensions/fm-primary-pi-watch.ts tests/fm-pi-watch-extension.test.sh
git commit -m "fix(pi): clear watcher status on shutdown"
```

---

### Task 4: Close ordinary-worktree and non-goal coverage, then run the full static matrix

**Files:**

- Modify: `tests/fm-pi-watch-extension.test.sh`.
- Verify: `.pi/extensions/fm-primary-pi-watch.ts`.
- Verify: `tests/fm-pi-primary-types.test.sh`.

**Interfaces:**

- Produces deterministic test 10 for ordinary task-worktree absence.
- Produces deterministic test 11 for forbidden dependencies and timers.
- Does not add production interfaces.

- [ ] **Step 1: Add characterization test 10 for ordinary task-worktree absence**

Extend the existing linked-worktree fixture with a fake `setStatus` recorder.
Keep the fixture unmarked by `.fm-secondmate-home` and assert:

```javascript
assert.equal(registrations, 0);
assert.deepEqual(statusWrites, []);
```

Name the test entry:

```bash
test_pi_status_absent_in_task_worktree
```

Run:

```bash
tests/fm-pi-watch-extension.test.sh
```

Expected: this test already passes if the candidate's `supervisingHome()` gate remains before client registration.
Treat a pass here as the required characterization test, not permission to move the gate.

- [ ] **Step 2: Add test 11 for static non-goals**

Name and invoke:

```bash
test_pi_status_static_non_goals
```

Use these exact checks:

```bash
text=$(cat "$EXT")
assert_contains "$text" '"firstmate-pi-watcher"' "Pi watcher status key drifted"
assert_contains "$text" 'customType: "firstmate-watcher-wake"' "Pi watcher custom wake type drifted"
assert_not_contains "$text" 'sendUserMessage' "Pi watcher still sends a synthetic user message"
for forbidden in 'setInterval(' 'setWidget(' 'setFooter(' 'gh pr' 'backlog.md' 'fm-pr-' 'tmux job' 'stall watchdog'; do
  assert_not_contains "$text" "$forbidden" "Pi watcher status introduced forbidden surface: $forbidden"
done
timer_lines=$(grep -n 'setTimeout(' "$EXT" || true)
[ "$(printf '%s\n' "$timer_lines" | grep -c .)" -eq 1 ] \
  || fail "Pi watcher must keep exactly one generic bounded cleanup timer"
assert_contains "$timer_lines" 'setTimeout(() => finish(false), milliseconds)' \
  "Pi watcher contains a non-cleanup timer"
assert_contains "$text" 'timer.unref()' "Pi watcher cleanup timer can keep Pi alive"
```

The timer allow-list permits only the one-shot timer inside `settlesWithin`; callers bind it to `STOP_GRACE_MS` or `STOP_KILL_GRACE_MS`.
It does not permit a polling or status-refresh timer.

- [ ] **Step 3: Record the exact 11-test mapping at the top of the existing test file**

Add this comment without duplicating the design contract:

```bash
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
```

- [ ] **Step 4: Run the full deterministic verification matrix**

Run:

```bash
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
shellcheck bin/*.sh bin/backends/*.sh tests/*.sh
```

Expected: both test scripts exit 0, the type test names Pi 0.80.6, and `shellcheck` prints no diagnostics.

- [ ] **Step 5: Commit the completed deterministic contract**

```bash
git add tests/fm-pi-watch-extension.test.sh
git commit -m "test(pi): cover watcher status contract"
```

---

### Task 5: Verify the clean live Pi status sequence

**Files:**

- Modify: `tests/fm-pi-primary-live-e2e.test.sh`.

**Interfaces:**

- Produces `capture_current()` for the current tmux viewport.
- Produces `wait_for_status(value)` for an exact current status entry.
- Produces `wait_for_status_absent()` for clear during unload.
- Preserves the existing isolated `PI_CODING_AGENT_DIR`, marked supervising home, watcher ownership, `/reload`, `/quit`, and process-cleanup checks.

- [ ] **Step 1: Add live status helpers before changing the scenario**

Add:

```bash
capture_current() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true
}

current_status_lines() {
  capture_current | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

wait_for_status() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    current_status_lines | grep -Fxq "$expected" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  capture_current >&2
  return 1
}

wait_for_status_absent() {
  local attempts=${1:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if ! current_status_lines | grep -Eq '^(offline|watching|handling wake|attention)$'; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  capture_current >&2
  return 1
}
```

Do not use substring matching for `offline` or `watching` because model text can contain those words.

- [ ] **Step 2: Make the live wake pause in `handling wake` before re-arm**

After the initial charter settles, require:

```bash
wait_for_status offline || fail "fresh watcher extension did not show offline"
```

After the first native arm, require:

```bash
wait_for_status watching || fail "owned arm did not show watching"
```

Change the initial model instruction so the actionable follow-up drains the queue and replies exactly `WAKE-HANDLED` without re-arming.
After writing the synthetic status event, require:

```bash
wait_for_status "handling wake" 240 || fail "delivered actionable wake did not show handling wake"
wait_for_text "WAKE-HANDLED" 180 || fail "Pi did not settle after handling the watcher wake"
```

Send a separate prompt to call `fm_watch_arm_pi` once and reply `REARMED`, then require:

```bash
wait_for_status watching 180 || fail "successful re-arm did not restore watching"
```

- [ ] **Step 3: Verify reload and quit ownership**

Send `/reload`, then require the old client status to disappear before accepting the replacement state:

```bash
wait_for_status_absent 40 || fail "reload did not clear the old watcher status"
```

Then require the new instance's first stable status to be:

```bash
wait_for_status offline 120 || fail "reloaded watcher instance did not start offline"
```

Re-arm once, require `watching`, and retain the existing checks that the old arm and watcher processes died.
On `/quit`, require `wait_for_status_absent 40`, then require Pi to exit 0 and retain the existing checks that the final arm and watcher processes died.
The deterministic unit test remains authoritative for the `undefined` clear call because the TUI no longer exists after quit.

- [ ] **Step 4: Run the opt-in isolated live regression**

Run:

```bash
FM_PI_LIVE_E2E=1 \
FM_PI_LIVE_AUTH_FILE="$HOME/.pi/agent/auth.json" \
tests/fm-pi-primary-live-e2e.test.sh
```

Expected:

```text
ok - Pi 0.80.6 watcher status moved offline -> watching -> handling wake -> watching, reloaded to offline, and cleared with clean process shutdown
```

- [ ] **Step 5: Re-run deterministic tests after the live-script edit**

Run:

```bash
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
shellcheck tests/fm-pi-primary-live-e2e.test.sh tests/fm-pi-watch-extension.test.sh
```

Expected: both test scripts exit 0 and `shellcheck` prints no diagnostics.

- [ ] **Step 6: Commit the live verification**

```bash
git add tests/fm-pi-primary-live-e2e.test.sh
git commit -m "test(pi): verify live watcher status sequence"
```

---

## Transition and precedence matrix

| Event | Required result | Test |
| --- | --- | --- |
| Real supervising-home `session_start` before arm | `offline` | 1 |
| Arm request begins while lock recovery or spawn is pending | Preserve current value | 1, 2, 9 |
| Current owned arm record is installed | `watching` | 2 |
| Duplicate request finds current owned arm | Preserve `watching`, no write, spawn, or generation increment | 7 |
| Actionable `signal`, `stale`, `check`, or `heartbeat` wake is accepted by `sendMessage` | `handling wake` | 3 |
| Current generation successfully re-arms | `watching` | 3 |
| Lock recovery, lock ownership, or spawn cannot establish ownership | `attention` | 4 |
| External healthy watcher reports ownership elsewhere | `attention` | 4 |
| Current child errors, exits nonzero, exits by signal, or exits cleanly without an actionable reason | `attention` | 4 |
| Actionable `sendMessage` throws | `attention`, never `handling wake` | 4 |
| Normal intentional stop settles with a loaded client | `offline`, no wake and no transient `attention` | 5 |
| Reload or quit begins for the last client | Clear key before awaiting startup or child settlement | 6, 9 |
| Replacement extension starts after reload | Fresh `offline` | 6 |
| Old-record callback arrives after replacement or clear | No write, wake, or ownership change | 8 |
| Pending startup settles after last-client shutdown | No write after clear and no child spawn | 9 |
| Extension loads from an ordinary task worktree | Key absent and no registrations | 10 |
| Source audit runs | No status polling or excluded product surface | 11 |

Apply callback precedence in this exact order:

1. Return if the record is already settled.
2. Return after resolving completion if the record is not both `coordinator.current` and the current `generation`.
3. Clear current ownership for the valid record.
4. Return without wake or status if shutdown has begun or the record has an intentional-stop reason.
5. Classify an actionable watcher line and call `sendMessage`.
6. Publish `handling wake` only when that call returns normally and the generation is still current.
7. Publish `attention` when actionable delivery throws.
8. Otherwise classify child error, ownership output, signal, nonzero exit, or unexplained clean exit as `attention`.

Shutdown starts by clearing the client and setting `shuttingDown` before it awaits anything.
No callback, promise finalizer, or cleanup deadline may publish after that point.

---

## Final self-review checklist

- [ ] Compare every event in the approved design table with the transition matrix above.
- [ ] Confirm the 11 numbered tests exist and are invoked exactly once.
- [ ] Confirm cancelled pending startup and ordinary task-worktree absence are both covered.
- [ ] Search for key drift with `rg -n 'firstmate[.-]pi[.-]watcher' .pi tests docs/superpowers/plans/2026-07-10-pi-watcher-status-implementation.md` and require every status-key occurrence to be `firstmate-pi-watcher`.
- [ ] Search for the obsolete wake API with `rg -n 'sendUserMessage' .pi/extensions/fm-primary-pi-watch.ts tests/fm-pi-watch-extension.test.sh` and require no matches.
- [ ] Search for forbidden status timers with `rg -n 'setInterval|setTimeout' .pi/extensions/fm-primary-pi-watch.ts`; allow only the existing one-shot bounded cleanup timers behind `settlesWithin`, `STOP_GRACE_MS`, and `STOP_KILL_GRACE_MS`.
- [ ] Run the writing-plans placeholder scan and remove every unresolved marker or deferred instruction.
- [ ] Confirm `ArmRecord` owns no Pi runtime closure, every active client owns one `WakeSender`, and settlement routes through only the newest active client.
- [ ] Confirm `StatusUi.setStatus(key, text)` accepts `string | undefined` and every clear passes `undefined`.
- [ ] Confirm every status callback checks current record, current generation, active client, and shutdown state before writing.
- [ ] Confirm output remains incremental and bounded, structured wake details preserve truncation metadata, and status changes never rescan unbounded process output.
- [ ] Confirm intentional stop and process exit retain detached process-group TERM-to-KILL cleanup with bounded waits and no direct-child-only fallback as the primary path.
- [ ] Confirm the old client clears on reload, the replacement starts `offline`, and quit clears before process cleanup.
- [ ] Confirm the live script observes `offline` -> `watching` -> `handling wake` -> `watching` without combining the wake and re-arm into one prompt.
- [ ] Confirm no PR, backlog, decision, widget, custom-footer, polling, jobs, tmux-job, or stall-watchdog behavior appears in the changed extension.

## Execution handoff

Plan complete at `docs/superpowers/plans/2026-07-10-pi-watcher-status-implementation.md`.
Implement it task by task with the required execution sub-skill, keeping each red-green cycle and commit boundary intact.
