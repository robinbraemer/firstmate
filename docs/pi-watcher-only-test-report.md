# Pi watcher-only native supervision test

Date: 2026-07-10
Candidate basis: `283bb84d924454c461ec4092473e2e98c644370a`, revised by captain correction to remove Pi turn-end supervision.
Result: PASS for operational watcher-only reload, actionable wake injection, drain, and re-arm.

`/reload` completed with `.pi/extensions/` containing only `fm-primary-pi-watch.ts`.
The watcher marker was `sha256:991dfa510dfb75a154b36064d38382f21398a070fe8f5304e51b7f8caca0049f` for Pi PID `34779`, and the session lock also named PID `34779`.

Native arm returned `watcher: started Pi extension arm child 3`.
The attached process tree was Pi `34779` -> arm `72552` -> watcher `72565`.
The watcher lock recorded the operational home, exact watcher path, PID identity, and a fresh beacon.

A unique watcher-only completion signal `done: PI-WATCHER-ONLY-NATIVE-WAKE-283BB84` was emitted without direct post-write inspection.
The candidate watcher injected this exact actionable follow-up into the same Pi session:

```text
FIRSTMATE WATCHER WAKE: signal: /Users/robin/.treehouse/firstmate-b8697d/3/firstmate/state/pi-watcher-only-test.status /Users/robin/.treehouse/firstmate-b8697d/3/firstmate/state/pi-watch-life-k2.turn-ended

Run bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.
```

The queue drained both coalesced signal records, including the unique watcher-only status.
Native re-arm returned `watcher: started Pi extension arm child 4`.
The old arm/watcher `72552/72565` were gone.
The replacement process tree was Pi `34779` -> arm `78664` -> watcher `78677`, with matching lock identity and a 13-second-old beacon at capture.
Detailed evidence:

- `state/pi-native-test-drive/watcher-only-reload-setup.txt`
- `state/pi-native-test-drive/watcher-only-after-reload.txt`
- `state/pi-native-test-drive/watcher-only-wake-drain.txt`
- `state/pi-native-test-drive/watcher-only-native-wake-evidence.txt`
