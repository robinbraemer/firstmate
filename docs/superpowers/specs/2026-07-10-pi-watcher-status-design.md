# Pi watcher status design

Date: 2026-07-10

## Goal and user-visible contract

The Pi watcher extension exposes the health and lifecycle of Firstmate's native watcher supervision in Pi's existing extension-status area.
The status is visible whenever the extension is loaded in a real Firstmate home, even before an arm child has existed.
It reports only the extension's owned watcher lifecycle, not the state of project work.

The four exact visible strings are `Firstmate watcher: offline`, `Firstmate watcher: watching`, `Firstmate watcher: handling wake`, and `Firstmate watcher: attention`.
The extension updates the status from coordinator events rather than from a timer or a filesystem poll.

## Status key and state vocabulary

The extension exclusively owns the Pi `setStatus` key `firstmate.pi.watcher`.
No other Firstmate component writes that key.
The coordinator for the effective `FM_HOME` is the single source of truth for the value projected through that key.

| State | Meaning |
| --- | --- |
| `offline` | The extension is loaded, but no owned arm child exists because none has started yet or the most recent child ended through an intentional normal stop. |
| `watching` | The current-generation owned arm child is running and owns native watcher wake delivery for this Firstmate home. |
| `handling wake` | The current-generation arm produced an actionable watcher exit and delivered its wake to Pi, and no later arm has successfully started. |
| `attention` | The current arm attempt failed unexpectedly, supervision ownership was refused or found elsewhere, wake delivery failed, or another current-generation condition requires operator intervention. |

`offline` is the initial value on extension load when the coordinator has no stronger current state.
The absence of an arm child does not by itself hide the status.
Only final extension or session shutdown clears the key.

## Event and transition table

The coordinator serializes these events per effective Firstmate home.
A transition may update the visible status only if its client is active and its arm generation is still current.

| Event | Condition | Resulting status | Required behavior and precedence |
| --- | --- | --- | --- |
| Extension client loads | No current arm and no retained actionable or failure state exists | `offline` | Publish immediately through the dedicated key. |
| Extension client loads or reloads | A coordinator already has a current visible state | Existing coordinator state | Project the coordinator's current state into the newly active client instead of resetting it to `offline`. |
| Arm request begins | The session owns the Firstmate lock and no current arm exists | Existing status | Enter the coordinator's internal `starting` state without inventing a fifth user-visible state. |
| Arm start succeeds | The spawned child is installed as the current generation and is running | `watching` | This transition is the only event that clears `handling wake` or `attention` during ordinary operation. |
| Duplicate arm request | The coordinator already owns a healthy current-generation child | `watching` | Reuse the existing arm and do not spawn, stop, or renumber it. |
| Arm request is refused | The session does not own the Firstmate lock | `attention` | Do not spawn a child, and surface the existing refusal message through the command or tool result. |
| Arm reports external healthy ownership | The owned child reports that another watcher is healthy instead of owning wake delivery itself | `attention` | Treat this as an ownership issue, not as `watching` and not as a successful duplicate arm. |
| Arm start or child fails | Spawn throws, the child emits an error, exits nonzero without an actionable reason, or otherwise cannot establish or retain owned supervision | `attention` | Preserve the existing failure wake or notification behavior. |
| Child exits unexpectedly without an actionable reason | The current generation was not intentionally stopped and no recognized failure line explains the exit | `attention` | An unexplained clean exit is not a normal stop and must not silently look `offline`. |
| Actionable child exit is classified | The current generation emits `signal`, `stale`, `check`, or `heartbeat` | Existing status until delivery settles | Clear the current child and attempt the existing Pi follow-up delivery without starting another arm automatically. |
| Actionable wake delivery succeeds | Pi accepts the current generation's follow-up wake | `handling wake` | Keep this state until a later arm start succeeds or final shutdown clears it. |
| Actionable wake delivery fails | Pi rejects the current generation's follow-up wake | `attention` | The failed delivery requires intervention and takes precedence over `handling wake`. |
| Intentional stop begins | The current child is marked with a stop reason before it is signalled | Existing status | The stop marker must be installed before `SIGTERM` so close or error callbacks cannot report a false failure. |
| Intentional stop finds no child | At least one extension client remains loaded | `offline` | A completed normal stop is offline even when there was no child left to settle. |
| Intentional stop settles | The stopped generation is still current and at least one extension client remains loaded | `offline` | Suppress wake injection and failure classification for the intentional stop. |
| Successful re-arm | A later generation is installed and running after `handling wake`, `attention`, or `offline` | `watching` | The new generation supersedes every older terminal callback and status. |
| Stale arm callback | The callback's record or generation is no longer current | No change | Do not inject a wake, clear a child, or update status. |
| Final extension or session shutdown | The last active extension client is unloading | Key cleared | Mark any child stop as intentional, clear the dedicated key, stop the child, and reject later status writes from that client or generation. |

Final shutdown first invalidates the client and current generation, clears the key, and only then waits for child settlement.
For an active client, the current-generation check precedes all outcome classification.
Intentional-stop classification then precedes actionable and failure classification for the same child, and actionable classification precedes generic failure classification.
This ordering prevents a late callback from recreating stale UI or showing false `attention` during a normal stop.

## Reload, ownership, generation, and shutdown semantics

The process-global coordinator remains keyed by the resolved Firstmate home and owns the child, lifecycle state, generation counter, and active extension clients.
A reload registers its replacement client with that coordinator and receives the current visible state.
If a replacement client is already active, retirement of the old client is an ownership transfer rather than a final unload, so it must not stop the shared child or leave the shared key cleared.
If lifecycle ordering temporarily clears the old client's key, the active replacement immediately reprojects the coordinator state before control returns to the UI.

Retirement of the last client during reload, or an explicit stop while a client remains loaded, marks the current child as intentionally stopping before sending its termination signal.
Retirement of an old client does not stop the child when a replacement client is already active.
An intentionally stopped child's close and error callbacks produce neither wake injection nor `attention`.
A completed intentional stop becomes `offline` when the extension remains loaded.
A final session or extension shutdown clears `firstmate.pi.watcher` instead of publishing `offline`, because no loaded extension remains to own the display.

Every arm record captures a monotonically increasing generation.
Only a record that is both the coordinator's current record and equal to the coordinator's current generation may change child ownership, deliver a wake, or publish status.
A successful re-arm therefore prevents late close, error, delivery-resolution, and stop-resolution callbacks from an old generation from overwriting `watching` or any later state.

A duplicate request is healthy only when the coordinator itself owns the current child.
A lock refusal or an arm wrapper report of an external healthy watcher is an ownership problem and publishes `attention`.
The status does not infer ownership by polling process or lock state after an event.

## Separation from a future AI-maintained PR and decision snapshot

This extension reports only native Pi watcher supervision health and lifecycle.
Any future PR, CI, backlog, task, or pending-decision interface must read a separate snapshot maintained by the AI outside this extension.
That product-state snapshot must not add GitHub queries, backlog parsing, or task-state logic to the Pi watcher extension.

## Non-goals

- No widget or custom footer.
- No polling loop.
- No generic jobs UI, job list, or tmux job manager.
- No Tau feature copying beyond a minimal lifecycle lesson already adopted elsewhere.
- No stall watchdog.
- No GitHub, PR, CI, backlog, decision, or task-state logic in the watcher extension or watcher status.
- No status implementation or implementation tests in this documentation change.

## Focused future test plan

Future implementation tests should use a fake Pi UI that records `setStatus` calls for the dedicated key and controlled arm children that emit each lifecycle outcome.

- Assert that extension load publishes `Firstmate watcher: offline` before any arm request.
- Assert that a successful owned start publishes `watching`, and a duplicate owned arm preserves `watching` without spawning another child.
- Assert that each actionable watcher reason publishes `handling wake` only after follow-up delivery succeeds and retains it until successful re-arm.
- Assert that spawn errors, child errors, unexplained exits, nonzero failures, wake-delivery failures, lock refusal, and external healthy ownership publish `attention`.
- Assert that intentional stop marks the generation before termination, injects no wake, never publishes transient `attention`, and leaves a loaded extension at `offline`.
- Assert both reload orderings, replacement-before-retirement and retirement-before-replacement, preserve or reproject the coordinator state without an unintended stop or stale blank status.
- Assert that callbacks and delivery completions from an old generation cannot alter the current generation's child, wake delivery, or status.
- Assert that final session and process-exit cleanup clear `firstmate.pi.watcher`, stop the owned child intentionally, and ignore later callbacks.
- Assert that no timer, polling loop, widget, custom footer, GitHub query, or backlog reader is introduced.
