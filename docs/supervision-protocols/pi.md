Mode: Pi extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm Pi loaded both tracked project extensions.
3. A trusted plain Firstmate checkout auto-loads them, and explicitly naming the same canonical files with `-e` is safely deduplicated by Pi.
4. For an unattended firstmate or secondmate launch, use `--approve -e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__` so project resources are approved for that run and the tracked extensions still resolve to one canonical source each.
5. Bare `-e` does not suppress Pi's project-trust dialog.
6. Arm supervision with the `fm_watch_arm_pi` tool.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypass extension-owned cleanup.
7. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live Pi process, and sends a follow-up user message when the child exits with an actionable watcher reason.
8. One process-wide coordinator per effective `FM_HOME` owns the attached arm generation.
   Duplicate factories share that coordinator, stale generation callbacks cannot clear a replacement, and intentional session shutdown waits for the arm child without sending a false wake.
9. If the extension says the watcher is already healthy, do not start another cycle.
10. If the extension reports a watcher failure, drain queued wakes, inspect the failure text, and restart Pi with both extensions loaded if needed.
11. Never use shell `&` for watcher supervision.
    The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_PI_TURNEND_EXT__`).

The turn-end guard extension lives at `__FM_PI_TURNEND_EXT__`.
The watcher extension lives at `__FM_PI_EXT__`.
Both are tracked, project-local `.pi/extensions/*.ts` files.
Do not install or copy either extension globally.
Pi deduplicates repeated canonical paths, not logical extension identities, so a distinct copied watcher registers `fm_watch_arm_pi` twice and aborts startup with a tool conflict.
`bin/fm-session-start.sh` reports when the running Pi session has not loaded both required tracked files.

Verification on 2026-07-10 used Pi 0.80.6, isolated `PI_CODING_AGENT_DIR` and `FM_HOME` directories, `packages: []`, only the two tracked extensions, and dedicated tmux sockets.
Command run for the complete interactive regression: `FM_PI_LIVE_E2E=1 FM_PI_LIVE_AUTH_FILE="$HOME/.pi/agent/auth.json" tests/fm-pi-primary-live-e2e.test.sh`.
The regression launched a marked secondmate with `--approve` and both explicit same-path tracked extensions, accepted its charter without a trust dialog, preserved project skills, and displayed each extension once.
Stock Pi Bash ran `bin/fm-lock.sh`, and the recorded fleet lock named the direct parent Pi process.
One blind turn produced one bounded guard follow-up, one synthetic actionable status produced one injected watcher follow-up and durable queue drain, and native re-arm started a new attached generation.
`/reload` terminated the prior arm and watcher without `fm-watch-arm.sh exited 143`, without an empty wake, and without clearing the replacement generation.
`/quit` left the tmux pane with exit status 0 and left neither arm nor watcher alive.
A separate distinct-path copied watcher control exited 1 with `Tool "fm_watch_arm_pi" conflicts with ...`.
Command run for the installed-type contract: `tests/fm-pi-primary-types.test.sh` with TypeScript on PATH.
Observed output: `ok - Pi primary extensions pass strict no-emit typecheck against Pi 0.80.6`.

The external live-fire acceptance lane uses `tests/fm-pi-live-acceptance-helper.sh` only to record evidence and emit its known status.
The helper never owns or backgrounds supervision.
The dedicated Pi session itself must receive the follow-up, drain the queue, re-arm, reload without a false wake, and quit cleanly before the candidate proceeds to validation.
