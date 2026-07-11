# Native Pi supervision implementation plan

## Goal

Ship native, unattended watcher supervision for Pi primaries and persistent secondmates through the single tracked watcher extension while preserving Firstmate's existing bash watcher, home lock, and durable wake queue.

## Product contract

- Keep `.pi/extensions/fm-primary-pi-watch.ts` as the only tracked Pi extension.
- Keep Pi supervision watcher-only, with no Pi turn-end guard or blind-turn follow-up.
- Keep ordinary non-Pi turn-end guard behavior primary-scoped.
- Launch persistent Pi secondmates with one-run `--approve` and one canonical watcher `-e` path.
- Keep ordinary Pi crewmate turn-end marker behavior unchanged.
- Keep runtime free of global extensions, background shell jobs, daemons, sockets, and extra packages.

## Extension lifecycle

1. Resolve `FM_ROOT`, `FM_HOME`, state, config, watcher arm, and lock paths from the extension's canonical file path and effective environment.
2. Store a process-wide coordinator keyed by resolved `FM_HOME`.
3. Share startup and the current owned arm across duplicate factories for that home.
4. Delegate non-owned lock states to `bin/fm-lock.sh` and re-check ownership before arming.
5. Spawn `bin/fm-watch-arm.sh --restart` as an owned detached process group with effective home and config overrides.
6. Inject one follow-up for actionable, failed, or unexpectedly signaled exits.
7. Suppress follow-ups for intentional reload, quit, process exit, and ownership transfer.
8. Cancel and await an in-progress startup when the final extension client shuts down.
9. Reject stale generation callbacks that attempt to clear or notify over a replacement.
10. Run the shared watcher-arm PreToolUse checker from the watcher's `tool_call` handler and block only on checker exit 2.

## Shell authority

1. Keep `bin/fm-lock.sh` authoritative for process identity and stale-lock decisions.
2. Recognize only verified Pi shapes: the exact `pi` command and Node executing `@earendil-works/pi-coding-agent/dist/cli.js`.
3. Keep generic Node untrusted.
4. Serialize home lock acquisition and reclamation with the existing home-scoped portable mutex contract.
5. Preserve live other-harness-owner refusal.
6. Keep tmux liveness classification aligned with the same verified Pi process shapes.

## Loading and diagnostics

1. Render only the watcher extension path in the Pi supervision protocol.
2. Have session start validate only `.pi-watch-extension-loaded` against the current watcher content hash and owning Pi ancestry.
3. Replace only the `__PIWATCH__` secondmate launch placeholder.
4. Document same-canonical-path dedupe and distinct-copy registration conflict.
5. Keep the watcher extension project-local and tracked.

## Hermetic acceptance

1. Verify the watcher file is self-locating, self-hashing, and exposes one tool plus one command.
2. Verify actionable output drains through one Pi follow-up and can re-arm a replacement generation.
3. Verify reload and quit intentionally stop the owned process group without false wake injection.
4. Verify duplicate factories share one lock claim and one arm.
5. Verify a stale callback cannot clear a replacement generation.
6. Verify shutdown during a delayed lock claim leaves no arm, watcher, or wake.
7. Verify stale and PID-reused non-harness locks recover through the shell authority.
8. Verify a genuine live Pi owner is refused and concurrent claimers have one atomic winner.
9. Verify the PreToolUse seatbelt remains wired through the single watcher extension.
10. Verify the mandatory TypeScript test exits on compiler failure and prints success only after a passing compile.

## Live acceptance

1. Create a fresh worktree-local lab with `mktemp` and an ownership sentinel.
2. Use an isolated `PI_CODING_AGENT_DIR`, empty package inventory, copied auth, dedicated tmux socket, and one tracked watcher extension.
3. Prove explicit plus auto-discovered same-path loading registers the watcher once.
4. Prove a distinct watcher copy fails with the duplicate tool conflict.
5. Launch a marked secondmate with `--approve -e <canonical-watcher>` and confirm there is no trust prompt.
6. Acquire the home lock through stock Pi Bash and verify the recorded PID is the direct Pi parent.
7. Arm through `fm_watch_arm_pi`, emit a known actionable status, drain, and re-arm.
8. Reload and prove the prior arm and watcher die without a turn-end message, empty wake, exit-143 report, or false failure.
9. Re-arm after reload, quit cleanly, and prove no child survives.
10. Record external evidence with the helper, including watcher-only inventory and a clean reload assertion.

## Validation commands

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-arm-pretool-check.test.sh
tests/fm-session-start.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-turnend-guard.test.sh
tests/fm-secondmate-liveness.test.sh
shellcheck bin/*.sh bin/backends/*.sh tests/*.sh
FM_PI_LIVE_E2E=1 FM_PI_LIVE_AUTH_FILE=<isolated-auth.json> tests/fm-pi-primary-live-e2e.test.sh
```
