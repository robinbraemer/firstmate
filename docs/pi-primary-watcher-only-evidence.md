# Primary Pi watcher-only fleet evidence

Date: 2026-07-10
Result: PASS

The primary fleet test is healthy with watcher-only Pi supervision.

- Candidate marker: `sha256:991dfa510dfb75a154b36064d38382f21398a070fe8f5304e51b7f8caca0049f`.
- Live Pi PID: `80120`.
- Native `fm_watch_arm_pi` arm child PID: `92114`.
- Owned watcher PID: `92127`.
- Home/session lock and watcher lock files are present and identity-matched.
- Watcher beacon is fresh.
- A duplicate native arm call returns healthy and does not create another arm or watcher.
- pi-tau is absent.

This evidence complements the tracked [secondmate operational watcher-only proof](pi-watcher-only-test-report.md) and the original clean-stock live-fire proof recorded operationally at `data/pi-live-fire-a8/report.md`.
The candidate must preserve watcher-owned actionable injection and re-arm.

## Detached restart blocker resolution

Date: 2026-07-10.
Pi version: 0.80.6.
Candidate commit: `e3a32ff4ea5a084ffd4ca916b46875ab5ced5f28`.

The release blocker was caused by `supervisingHome()` treating every linked Git worktree as an ordinary task worktree.
Treehouse primary homes are themselves linked worktrees, so the extension factory returned before it registered `fm_watch_arm_pi`, registered `/fm-watch-arm-pi`, or wrote `.pi-watch-extension-loaded`, even when Pi received the candidate path through `-e`.
The corrected predicate admits a primary-shaped extension root when its canonical path is the effective `FM_HOME`, while a linked task worktree whose extension root differs from `FM_HOME` remains inert.

The detached restart path now replaces the old Pi at the tmux pane boundary with `respawn-pane -k`.
It passes every launch value as one shell-quoted argument to `tests/fm-pi-detached-launch-helper.sh`, whose final action is `exec env ... pi`, so no launch text enters Pi's composer and no nested wrapper or Pi process remains.
The live lab deliberately used spaces in the project and Pi-agent paths.

Exact command:

```sh
env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_PI_LIVE_E2E=1 FM_PI_LIVE_AUTH_FILE="$HOME/.pi/agent/auth.json" tests/fm-pi-primary-live-e2e.test.sh
```

Exact output:

```text
evidence - candidate_hash=sha256:a55a0d761425172d198833edd67687272e6dd6e50e9bf400e0906720896100ff candidate_pid=32126 lock_pid=32126 arm_pgid=35991 watcher_pid=36004 old_pi_pid=32001 all_clean=true
ok - Pi 0.80.6 isolated detached restart loaded the watcher once, registered its tool and command, locked, woke, reloaded, re-armed, and left no orphan descendants
```

The registration probe observed exactly one watcher tool and one watcher command during `session_start`.
The loaded marker contained the candidate hash and PID `32126`, `bin/fm-session-start.sh` accepted it after the same Pi acquired the home lock, and the lock named only PID `32126`.
The native arm owned process group `35991`, its watcher PID was `36004`, the earlier Pi PID `32001` was dead after replacement, clean quit removed the candidate arm and watcher, and the final lab-scoped process scan found no Pi descendant.
