# Pi Native Supervision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make native Pi primary and secondmate supervision deterministic across startup, wake, reload, recovery, and exit.

**Architecture:** Keep Firstmate's bash watcher, arm wrapper, home lock, and durable queue authoritative.
The tracked Pi watcher extension adds one process-wide per-home cancellation-aware coordinator, while narrowly scoped shell changes enable secondmate turn-end recovery and verified Pi process liveness.

**Tech Stack:** TypeScript Pi extensions, Bash 5, tmux 3.6a, Pi 0.80.6, shell behavior tests, strict TypeScript compilation.

## Global Constraints

- Use only the two tracked `.pi/extensions` files as Pi extension sources.
- Keep `bin/fm-watch-arm.sh --restart` as the only Pi arm entry point.
- Do not change watcher lock, beacon, or durable queue semantics.
- Do not add pi-tau, daemons, sockets, global extensions, or background-job dependencies.
- Classify ambiguous Node processes as `unknown`, never `dead`.
- Use one sentence per Markdown line and plain dashes.
- Write failing behavior tests before every production behavior change.

---

### Task 1: Cancellation-aware Pi arm ownership

**Files:**
- Modify: `tests/fm-pi-watch-extension.test.sh`
- Modify: `.pi/extensions/fm-primary-pi-watch.ts`

**Interfaces:**
- Consumes: `fm-watch-arm.sh --restart`, Pi `session_shutdown`, `sendUserMessage`, and the existing lock-ownership predicate.
- Produces: `globalThis.__firstmatePiWatchCoordinators`, keyed by resolved home, with one current generation and one attached child.

- [ ] **Step 1: Add coordinator lifecycle regressions**

Add real-child Node fixture tests that assert intentional reload shutdown waits for child cleanup and sends zero prompts, an unexpected actionable close sends one prompt, duplicate factories return one shared arm, and an error/late-close from an old generation cannot clear or notify over its replacement.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `bash tests/fm-pi-watch-extension.test.sh`.
Expected: FAIL because reload emits an exit-143 wake and duplicate factories start two children.

- [ ] **Step 3: Implement the minimal coordinator**

Replace module-local ownership with typed records equivalent to:

```ts
type CoordinatorState = "idle" | "starting" | "running" | "stopping";
type ArmRecord = {
  child: ChildProcess;
  generation: number;
  intentionalStopReason: string;
  settled: boolean;
  completion: Promise<void>;
  resolveCompletion: () => void;
  stdout: string;
  stderr: string;
};
type ArmCoordinator = {
  current: ArmRecord | null;
  generation: number;
  sequence: number;
  state: CoordinatorState;
  clients: Set<symbol>;
  exitListener?: () => void;
};
```

Use one typed `globalThis` map per process, generation-check both child callbacks, settle once, mark intentional before `SIGTERM`, await the last-client shutdown completion, and keep process-exit cleanup synchronous.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run: `bash tests/fm-pi-watch-extension.test.sh`.
Expected: all watcher-extension behavior tests pass with no leaked fixture child.

### Task 2: Fresh Pi secondmate launch and guard recovery

**Files:**
- Modify: `tests/fm-pi-watch-extension.test.sh`
- Modify: `tests/fm-turnend-guard.test.sh`
- Modify: `bin/fm-spawn.sh`
- Modify: `bin/fm-turnend-guard.sh`

**Interfaces:**
- Consumes: the existing Pi secondmate launch placeholders and `.fm-secondmate-home` marker.
- Produces: `pi --approve -e <tracked-turnend> -e <tracked-watch>` and supervising-home scope for marked secondmates.

- [ ] **Step 1: Add launch and scope regressions**

Require `--approve` before both tracked `-e` paths, forbid generated/global paths, change the secondmate hook expectation from silent to exit 2 when work is in flight, and retain the linked ordinary worktree no-op assertion.

- [ ] **Step 2: Run both focused tests and verify RED**

Run: `bash tests/fm-pi-watch-extension.test.sh && bash tests/fm-turnend-guard.test.sh`.
Expected: FAIL on missing `--approve` and inert secondmate guard.

- [ ] **Step 3: Implement the minimal launch and scope changes**

Change the Pi secondmate template to:

```sh
pi __MODELFLAG____EFFORTFLAG__--approve -e __PITURNEND__ -e __PIWATCH__ "$(cat __BRIEF__)"
```

Treat `.fm-secondmate-home` as an explicit supervising-home marker that bypasses only the plain-checkout equality check.
Keep unmarked linked worktrees excluded.

- [ ] **Step 4: Run both focused tests and verify GREEN**

Run: `bash tests/fm-pi-watch-extension.test.sh && bash tests/fm-turnend-guard.test.sh`.
Expected: both suites pass.

### Task 3: Verified Pi tmux liveness

**Files:**
- Modify: `tests/fm-secondmate-liveness.test.sh`
- Modify: `bin/backends/tmux.sh`

**Interfaces:**
- Consumes: tmux `pane_current_command`, `pane_pid`, and host `ps` foreground-process data.
- Produces: `alive|dead|unknown` with positive Pi classification only for a verified foreground Pi CLI shape.

- [ ] **Step 1: Add process-shape regressions**

Add fake tmux and `ps` fixtures for a `node` pane whose foreground group is an exact Pi CLI process, generic Node, malformed PID, and unreadable process data.
Keep shell-dead and other harness-alive cases.

- [ ] **Step 2: Run the liveness suite and verify RED**

Run: `bash tests/fm-secondmate-liveness.test.sh`.
Expected: FAIL because verified Pi still reports `unknown`.

- [ ] **Step 3: Implement the narrow Pi probe**

For `pane_current_command=node`, read `#{pane_pid}`, query `ps -o tpgid=`, then read `comm` and `args` for that exact foreground group leader.
Return alive only when both basenames identify `pi`; return unknown on every missing, generic, or malformed value.

- [ ] **Step 4: Run the liveness suite and verify GREEN**

Run: `bash tests/fm-secondmate-liveness.test.sh`.
Expected: all classifier and convergence cases pass.

### Task 4: Hermetic Pi type and harness tests

**Files:**
- Modify: `tests/fm-pi-primary-types.test.sh`
- Modify: `tests/fm-session-start.test.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the installed `pi` executable, optional `FM_PI_PACKAGE_DIR`, TypeScript compiler, and fake process harnesses.
- Produces: mandatory strict type coverage in CI and fake-harness runs isolated from inherited harness markers.

- [ ] **Step 1: Add portable discovery and isolation assertions**

Make the type script fail loudly rather than print a successful skip when `tsc` or Pi declarations are absent.
Discover a Bun-installed Pi package from `realpath "$(command -v pi)"`, search ancestor `node_modules` directories for hoisted `typebox` and `@types/node`, and unset `CLAUDECODE`, `PI_CODING_AGENT`, and `GROK_AGENT` in the fake session-start runner.

- [ ] **Step 2: Run the tests and verify the pre-CI fixture gap**

Run: `bash tests/fm-session-start.test.sh` and `bash tests/fm-pi-primary-types.test.sh`.
Expected before compiler setup: session-start passes and the type test fails loudly if no compiler is available.

- [ ] **Step 3: Add required CI compiler/package setup**

Add a behavior-job step that installs pinned Pi 0.80.6, TypeScript, typebox, and Node declarations into a runner-temp prefix, then exports its binary and Pi package paths through `GITHUB_PATH` and `GITHUB_ENV` before the behavior loop.

- [ ] **Step 4: Verify locally with a temporary compiler wrapper**

Run: `PATH="<temporary-bunx-tsc-wrapper>:$PATH" bash tests/fm-pi-primary-types.test.sh`.
Expected: strict no-emit compilation passes against Pi 0.80.6.

### Task 5: Isolated live Pi lifecycle regression and external acceptance helper

**Files:**
- Modify: `tests/fm-pi-primary-live-e2e.test.sh`
- Create: `tests/fm-pi-live-acceptance-helper.sh`
- Modify: `tests/fm-pi-watch-extension.test.sh`

**Interfaces:**
- Consumes: explicit opt-in auth/settings sources, Pi 0.80.6, a dedicated tmux socket, and the tracked extensions.
- Produces: one isolated live regression for canonical loading, stock Bash lock, secondmate guard, wake, reload, and exit.

- [ ] **Step 1: Make credentials and settings explicit**

Accept `FM_PI_LIVE_AUTH_FILE` and optional provider/model/thinking variables.
Create isolated settings with `packages: []`, copy only auth, and assert `pi list` reports no packages.

- [ ] **Step 2: Exercise the exact secondmate startup shape**

Launch with `.fm-secondmate-home`, `--approve`, and both explicit tracked paths.
Assert no trust prompt, one occurrence of each extension, a known project skill, and charter prompt acceptance.
Ask stock Pi Bash to run `fm-lock.sh` and assert the fleet lock records Pi's PID.

- [ ] **Step 3: Exercise canonical-path controls and lifecycle**

Assert trusted auto-load plus explicit same paths succeeds once.
Run a distinct-path copied watcher negative control and require Pi's duplicate-tool conflict.
Exercise one bounded guard, watcher wake/drain/re-arm, `/reload` with no false exit-143 wake, explicit post-reload re-arm, `/quit`, and dead child PIDs.

- [ ] **Step 4: Add the evidence-only acceptance helper**

Add `tests/fm-pi-live-acceptance-helper.sh` with `inventory`, `snapshot <phase>`, `emit <task-id>`, `drain`, and `verify-clean <arm-pid> <watcher-pid>` actions.
Require `FM_PI_ACCEPTANCE_ID`, `FM_PI_CANDIDATE_COMMIT`, `FM_PI_ACCEPTANCE_EVIDENCE`, and isolated `PI_CODING_AGENT_DIR`/`FM_HOME` inputs.
Record candidate/id, `pi --version`, `pi list`, isolated package/extension files, process ancestry, tool/command registration counts supplied by the session transcript, watcher lock files and beacon age, the known emitted status, exact queue drain, generation snapshots, reload transcript, and final child liveness.
The helper only reads evidence or emits the requested synthetic status; it never starts, replaces, or backgrounds supervision.
Add hermetic helper tests to the existing watcher-extension suite.

- [ ] **Step 5: Run the live regression**

Run: `FM_PI_LIVE_E2E=1 FM_PI_LIVE_AUTH_FILE="$HOME/.pi/agent/auth.json" bash tests/fm-pi-primary-live-e2e.test.sh`.
Expected: one success line naming Pi 0.80.6 and no leftover private tmux server or child.

### Task 6: Canonical documentation and final verification

**Files:**
- Modify: `docs/supervision-protocols/pi.md`
- Modify: `docs/configuration.md`
- Modify: `docs/turnend-guard.md`
- Modify: `docs/tmux-backend.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: verified behavior and exact live commands from Tasks 1-5.
- Produces: one canonical Pi protocol, updated empirical records, and a concise always-loaded secondmate guard fact.

- [ ] **Step 1: Update canonical docs**

Document one-run `--approve`, same-path deduplication, distinct-path conflict, coordinator cancellation semantics, secondmate primary-of-home recovery, the verified Pi process probe, and Pi 0.80.6 evidence.
Replace the old “trust-free fallback” and “Pi cannot be classified” statements.

- [ ] **Step 2: Update the concise always-loaded instruction**

Change only the existing AGENTS.md sentence that says the turn-end guard never runs in secondmate homes so it states that primary and persistent secondmate supervising homes are in scope while ordinary task worktrees remain excluded.

- [ ] **Step 3: Run focused and changed-script verification**

Run the focused watcher, turn-end, spawn, session-start, secondmate-liveness, watcher-lock, strict TypeScript, and live Pi commands from the brief.
Run every changed shell test and `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`.
Run the full `tests/*.test.sh` behavior suite.
Expected: zero failures and no silent type skip.

- [ ] **Step 4: Inspect and commit the candidate**

Run `git diff --check`, `git status --short`, inspect the complete diff, and confirm no `.no-mistakes` or personal fleet path is tracked.
Commit on `fm/pi-watch-life-k2` with terse messages and no co-author.
Do not push or open a PR.

- [ ] **Step 5: Report the candidate hash and stop for external acceptance**

Report the exact candidate commit hash before no-mistakes validation.
Stop while the supervisor launches a dedicated Herdr-visible Pi acceptance session from that commit with `--no-extensions`, an isolated `PI_CODING_AGENT_DIR`, and only the two tracked candidate extensions.
Do not claim PR readiness or append the final done status until the supervisor returns a passing acceptance id and evidence path.
