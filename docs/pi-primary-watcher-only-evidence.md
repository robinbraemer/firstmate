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
- The old turn-end marker names stale PID `49713` and is not evidence of a loaded handler.
- No Pi turn-end handler is loaded.
- No `TURN WOULD END BLIND` follow-up is injected.

This evidence complements the tracked [secondmate operational watcher-only proof](pi-watcher-only-test-report.md) and the original clean-stock live-fire proof recorded operationally at `data/pi-live-fire-a8/report.md`.
The candidate must preserve watcher-owned actionable injection and re-arm while deleting Pi turn-end guard loading, requirements, docs, and tests.
