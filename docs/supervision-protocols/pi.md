Mode: Pi extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm Pi loaded the tracked project watcher extension.
3. A trusted plain Firstmate checkout auto-loads it, and explicitly naming the same canonical file with `-e` is safely deduplicated by Pi.
4. For an unattended firstmate or secondmate launch, use `--approve -e '__FM_PI_EXT__'` so project resources are approved for that run and the tracked extension still resolves to one canonical source.
   Replace the Pi process from outside its composer; never submit a Pi launch command as a Pi prompt or start a nested Pi through its own Bash tool.
5. Bare `-e` does not suppress Pi's project-trust dialog.
6. Arm supervision with the `fm_watch_arm_pi` tool.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypass extension-owned cleanup.
7. The extension starts `bin/fm-watch-arm.sh --restart` as an owned detached process group and sends an actionable exit through Pi's custom `firstmate-watcher-wake` message with follow-up delivery and turn triggering.
   The wake is an extension-authored background event with structured details, never a user-role or captain-authored message.
8. One process-wide coordinator per effective `FM_HOME` owns the attached arm generation.
   Duplicate factories share that coordinator, stale generation callbacks cannot clear a replacement, output capture stays bounded, and every unexpected terminal outcome delivers exactly once.
   Intentional session shutdown suppresses false wakes, terminates the whole arm/watcher process group with bounded TERM-to-KILL escalation, and waits for cleanup before reload or quit completes.
   The Pi footer status key `firstmate-pi-watcher` reads `offline` before an arm, `watching` while the current arm owns supervision, `handling wake` after an actionable custom wake is accepted, and `attention` when ownership, startup, delivery, or an unexpected arm exit fails.
   A successful re-arm returns it to `watching`; reload and shutdown clear the old client status so a stale generation cannot overwrite the replacement.
9. If the extension says the watcher is already healthy, do not start another cycle.
10. If the extension reports a watcher failure, drain queued wakes, inspect the failure text, and restart Pi with the watcher extension loaded if needed.
11. Never use shell `&` for watcher supervision.
    The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the watcher extension at `__FM_PI_EXT__`).

The watcher extension lives at `__FM_PI_EXT__`.
It is the only tracked, project-local Pi extension.
Do not install or copy it globally.
Pi deduplicates repeated canonical paths, not logical extension identities, so a distinct copied watcher registers `fm_watch_arm_pi` twice and aborts startup with a tool conflict.
`bin/fm-session-start.sh` reports when the running Pi session has not loaded the required tracked file.

Verification on 2026-07-10 used Pi 0.80.6 with isolated Pi and Firstmate homes and only the tracked watcher extension.
Run `FM_PI_LIVE_E2E=1 FM_PI_LIVE_AUTH_FILE="$HOME/.pi/agent/auth.json" tests/fm-pi-primary-live-e2e.test.sh` for the opt-in interactive lifecycle regression.
Run `tests/fm-pi-primary-types.test.sh` with TypeScript on `PATH` for the installed Pi type contract.
