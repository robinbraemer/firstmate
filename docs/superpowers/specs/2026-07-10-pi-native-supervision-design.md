# Pi Native Supervision Design

Date: 2026-07-10.

## Goal

Make native Pi supervision deterministic for primary and secondmate homes on Pi 0.80.6 without replacing Firstmate's bash watcher, lock, or durable wake queue.

## Established failures

Pi deduplicates canonical extension paths, so trusted auto-discovery plus explicit `-e` of the same tracked file is safe while a distinct copied extension conflicts.
The tracked watcher extension currently owns an arm child only in a module-local variable.
Intentional `/reload` cleanup terminates that child with exit 143, and the stale close callback incorrectly reports a watcher failure.
Two factories in one Pi process can also start competing `--restart` arms because they do not share ownership state.
A fresh Pi secondmate blocks at project trust without `--approve`.
The turn-end predicate excludes secondmate homes, and tmux cannot identify Pi from `pane_current_command=node` alone.

## Design

### Canonical extension source

`.pi/extensions/fm-primary-pi-watch.ts` and `.pi/extensions/fm-primary-turnend-guard.ts` remain the only Pi extension sources.
Secondmate launch keeps explicit absolute paths to those same tracked files and adds the one-run `--approve` trust grant.
No generated or globally copied watcher extension is introduced.

### Per-home arm coordinator

The watcher extension stores a typed coordinator registry on `globalThis`, keyed by the resolved effective `FM_HOME`.
A coordinator owns one current arm record, a monotonically increasing generation and display sequence, an `idle|starting|running|stopping` state, registered factory clients, and one process-exit listener.
An arm record owns the child, captured stdout and stderr, an intentional stop reason, a settled latch, and a completion promise.

Every close and error callback captures its arm record.
Only the current unsettled record may clear coordinator state or notify Pi.
An error and its later close event settle once.
An intentional shutdown marks the record before sending `SIGTERM`, waits for completion in `session_shutdown`, and sends no follow-up.
Process exit performs the same mark-and-signal operation synchronously without waiting.
Multiple factories for one home share the same current child and process-exit listener.
The last registered factory to shut down stops the shared child and removes the listener.
Lock ownership remains mandatory before every arm attempt.

### Primary-of-home turn-end scope

`bin/fm-turnend-guard.sh` treats either a plain primary checkout or a marked `.fm-secondmate-home` as a supervising home.
A linked worktree without the secondmate marker remains excluded.
All existing watcher-health and bounded-follow-up behavior remains unchanged.

### Pi tmux liveness

A non-Node verified harness name remains directly alive and a bare shell remains dead.
When tmux reports `node`, the adapter reads the pane shell PID, obtains its foreground process-group ID, and inspects that exact process with `ps`.
It returns alive only when both the foreground process command basename and argv shape identify the Pi CLI.
Unreadable data and generic Node processes remain unknown.

## Invariants

- One effective home has one process-wide Pi arm coordinator and at most one attached arm child.
- One actionable or unexpected arm completion requests at most one follow-up.
- Intentional reload, quit, and ownership cleanup request zero follow-ups.
- An old generation cannot clear or notify over a newer generation.
- The bash watcher remains the only authority for watcher singleton, beacon, PID identity, and durable queue semantics.
- A secondmate can recover its own blind turn while an ordinary task worktree cannot.
- Ambiguous process identity never authorizes secondmate respawn.
- Native Pi supervision requires no pi-tau, daemon, socket, or global background-job extension.

## Verification boundary

Mandatory hermetic tests cover coordinator cancellation, duplicate factories, stale callbacks, exact extension paths, secondmate guard scope, Pi process classification, launch trust flags, inherited harness-marker isolation, and strict TypeScript compilation.
The opt-in live test uses a fresh `PI_CODING_AGENT_DIR`, `packages: []`, a dedicated tmux socket, only the two tracked extensions, and minimum copied auth/model settings.
It verifies same-path deduplication, the distinct-path conflict control, stock Bash lock ancestry, secondmate startup, guard, arm, wake, drain, re-arm, reload, quit, and child cleanup on Pi 0.80.6.
A tracked test-only acceptance helper records package and extension inventory, registration counts, process ownership, watcher lock identity, beacon freshness, emitted status, queue drain, arm generations, reload output, and post-quit cleanup without owning or replacing runtime supervision.
The candidate commit is reported before no-mistakes validation so a separate Herdr-visible Pi session can run that helper from the exact commit with only the two candidate extensions explicitly loaded.
