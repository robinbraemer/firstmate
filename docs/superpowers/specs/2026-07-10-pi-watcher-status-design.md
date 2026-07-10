# Pi Watcher Status Design

Date: 2026-07-10.

## Goal and user-visible contract

The native Firstmate Pi watcher extension exposes its supervision lifecycle through one dedicated Pi status entry.
The status reports only whether native watcher supervision is offline, watching, handling an actionable wake, or requires attention.
It is visible as `offline` immediately when the watcher extension loads in a real Firstmate supervising home, before any arm request or arm child exists.
The design adds no polling because every transition already belongs to the per-home arm coordinator lifecycle.

## Status key and state vocabulary

The extension owns the stable status key `firstmate-pi-watcher` exclusively.
No other Firstmate extension or future product-status feature writes that key.

The user-visible values are exactly:

- `offline` - the extension is loaded, but no current owned arm child exists after initial load or a normal intentional stop.
- `watching` - the current coordinator generation owns a running arm child and native watcher supervision for this home.
- `handling wake` - the current generation delivered an actionable watcher wake, and native supervision has not yet been successfully re-armed.
- `attention` - startup failed, ownership was refused or could not be recovered, an arm ended unexpectedly, or another condition requires operator intervention.
- Cleared - the extension or session is shutting down or has unloaded, so no stale Firstmate watcher status remains in Pi.

Cleared is a lifecycle action rather than a fifth displayed state.
The extension does not show a blank or placeholder value while loaded and active in a real supervising home.

## Event and transition table

| Event | Required transition | Notes |
| --- | --- | --- |
| Extension loads in a real supervising home | `offline` | Happens even before the first arm request. |
| Native arm request begins | Preserve current value | Lock recovery and process startup may not briefly claim success. |
| Arm child starts and becomes the current owned generation | `watching` | This is the only successful-start transition. |
| Duplicate arm request finds the current owned arm healthy | Preserve `watching` | It creates no child and does not reset wake state unless a current owned child actually exists. |
| Actionable watcher exit is delivered | `handling wake` | Remains until a later successful native re-arm. |
| Successful re-arm after an actionable exit | `watching` | The new current generation owns the transition. |
| Arm start fails | `attention` | Includes spawn, lock-recovery, and startup failures. |
| Ownership is refused or remains unresolved | `attention` | A live other owner and an unrecoverable stale/missing lock are operator-visible. |
| Current arm exits unexpectedly | `attention` | Includes non-actionable exit, signal, and cleanup failure. |
| Normal intentional stop outside session shutdown | `offline` | Intentional stop sends no wake and never flashes `attention`. |
| Session or extension shutdown begins | Clear key | Clearing takes precedence over every other transition. |
| New extension instance loads after reload | `offline` | It establishes fresh UI state before a new arm. |
| Stale callback from an old generation arrives | No change | It cannot overwrite the current generation or cleared shutdown state. |
| Extension loads outside a real supervising home | Clear key | Ordinary task worktrees do not advertise Firstmate supervisor health. |

## Transition ownership and precedence

The process-wide per-home coordinator is the sole writer of lifecycle states after extension load.
Each arm record carries its generation, and a callback may update status only while that record still owns the coordinator's current generation.
A stale error, close, or delivery callback from an older generation performs no status write.

Shutdown clearing has the highest precedence.
Once last-client shutdown begins, pending startup and arm callbacks cannot restore `offline`, `watching`, `handling wake`, or `attention` for that unloading instance.
The next extension instance created by reload sets `offline` from its own load lifecycle.

A successful current-generation start owns `watching` precedence over prior `offline`, `handling wake`, or `attention` values.
An actionable delivered exit owns `handling wake` until a successful current-generation re-arm, unless a later ownership refusal or unexpected failure requires `attention`.
An ownership refusal or failed start owns `attention` because operator action is required.
A duplicate healthy arm call preserves the status derived from the actual current generation rather than manufacturing a transition.

## Reload, ownership, generation, and shutdown semantics

Intentional reload, handoff, stop, and quit set the arm record's intentional-stop reason before signaling its process group.
Their expected terminal callbacks send no wake and never set `attention`.
For reload, the old extension clears the status key during shutdown, and the new extension sets `offline` when it loads.
There is no intermediate false failure state.

A normal intentional stop that does not unload the extension sets `offline` only after the owned arm is settled.
Session shutdown clears instead of showing `offline`, because no loaded extension remains to own the status.
If process-group cleanup exceeds its bounded stop contract, the current loaded instance may set `attention` before shutdown clearing, but stale callbacks after clear cannot restore it.

Lock acquisition and stale-lock recovery remain authoritative outside the status feature.
The status reflects their result only: recovered ownership followed by successful arm becomes `watching`, while refusal or unrecoverable ownership becomes `attention`.
The status feature never claims, rewrites, or polls a lock.

## Separation from future PR and decision status

The watcher status reports native Pi supervision health and lifecycle only.
Future PR, CI, backlog, task, or captain-decision UI must read a separate AI-maintained snapshot owned outside the watcher extension.
That snapshot must not reuse `firstmate-pi-watcher`, and the watcher extension must not import GitHub, backlog, or product-state logic.

## Non-goals

- No widget or custom footer.
- No polling loop or timer-driven status refresh.
- No generic jobs UI, job list, or tmux job manager.
- No Tau feature copying beyond already approved minimal lifecycle lessons.
- No stall watchdog.
- No GitHub, PR, CI, backlog, decision, or task-state logic.
- No implementation or test changes in this design-only slice.

## Focused test plan for a future implementation

A later implementation should add deterministic extension tests for these contracts:

1. Loading in a real supervising home sets `firstmate-pi-watcher` to `offline` before arm.
2. A successful first arm sets `watching`.
3. An actionable delivered wake sets `handling wake` until successful re-arm sets `watching`.
4. A failed start, unexpected exit, and ownership refusal each set `attention`.
5. A normal intentional stop sets `offline` without an intermediate `attention` write or wake delivery.
6. Reload and quit clear the key, suppress intentional-stop wake delivery, and let a new reload instance begin at `offline`.
7. A duplicate healthy arm preserves `watching` and creates no extra status transition.
8. A stale old-generation callback cannot overwrite `watching`, `handling wake`, `attention`, or a cleared shutdown key.
9. A pending startup cancelled by last-client shutdown cannot restore status after clear.
10. Loading in an ordinary task worktree clears or leaves absent the dedicated status key.
11. Tests assert there is no polling timer, widget, footer, jobs UI, or product-state dependency.

Live Pi verification should confirm the status sequence `offline` -> `watching` -> `handling wake` -> `watching`, followed by clear on `/reload` and `/quit`.
That live check remains separate from implementation unit tests and does not broaden the status feature into product-state UI.
