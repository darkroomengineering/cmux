# Session snapshot history + restore

Status: implemented.
Scope: cold-boot layout loss is a single-file-overwrite problem with no backup. This adds a
best-effort history of the session snapshot, a clean-shutdown flag on the snapshot itself, and
a manual restore path (`programa snapshot`) for recovering a lost layout after the fact.

## Problem statement

The live layout snapshot lives at one file:
`~/Library/Application Support/programa/session-<bundleId>.json`
(`Sources/SessionPersistence.swift`, `SessionPersistenceStore`). Every launch and every
lifecycle event (resign-active, terminate, window-unregister) overwrites this same file. There
is no history and no backup.

Three related loss paths motivate this feature:

1. **Cold boot / forced shutdown.** A machine restart or crash does not always give the app a
   chance to run `applicationWillTerminate`. The next launch may see a stale or partially
   written file, and as soon as it is read and the app re-saves (even with the same content),
   the previous state is gone with no way back.
2. **Explicit-open-intent clobber.** `prepareForExplicitOpenIntentAtStartup()`
   (`Sources/AppDelegate.swift`) nils `startupSessionSnapshot` when the launch carries an
   explicit open intent (a Finder "Open With", a CLI path argument, an Apple Event). Restore is
   skipped for that launch, and the very next `registerMainWindow` call still saves a snapshot
   of the *new* window state over the old file -- the old layout is silently discarded, even
   though the user never asked to discard it.
3. **No offline recovery.** Once either path above happens, the old layout is unrecoverable --
   there is nothing to reach for even manually.

## Design

### Rotation (best-effort, non-fatal)

`SessionPersistenceStore.rotateIntoHistory()` runs once per launch, before anything else can
touch the snapshot file -- called from `AppDelegate.prepareStartupSessionSnapshotIfNeeded()`
unconditionally, ahead of the `SessionRestorePolicy.shouldAttemptRestore()` gate that decides
whether restore itself runs. Rotation and restore are independent: rotation always runs;
restore only runs when the launch is eligible.

If a live snapshot file exists, it is **copied** (never moved -- the same-launch restore read
right after must see the file unchanged) into
`~/Library/Application Support/programa/session-history/<timestamp>-<bundleId>.json`, where
`<timestamp>` is the live file's modification time formatted `yyyyMMdd-HHmmss` in UTC. The
fixed-width timestamp prefix sorts newest-first lexicographically, so listing/pruning never
needs to parse filenames back into dates.

Two guards keep this cheap and non-intrusive:

- **Duplicate skip.** If the newest existing history entry has byte-identical content to the
  live file, rotation is a no-op -- a rapid relaunch (e.g. a crash loop) does not spam the
  history directory with copies of the same snapshot.
- **Prune to 10.** After copying, the history directory is pruned to the 10 newest entries
  (`SessionPersistencePolicy.maxSnapshotHistoryEntries`); anything older is deleted.

Every step (directory creation, read, copy, prune) is wrapped so a failure anywhere is
non-fatal and never blocks launch -- this is a best-effort archive, not a durability guarantee.

### Clean-shutdown flag

`AppSessionSnapshot.cleanShutdown: Bool?` records whether a given save happened during an
orderly quit. `nil` means "unknown" -- snapshots written before this field existed decode with
`cleanShutdown == nil`, not `false`; a missing signal is not the same claim as "this was an
unclean shutdown."

- `applicationShouldTerminate` / `applicationWillTerminate` (the user-initiated and
  system-initiated quit paths) save with `cleanShutdown: true`.
- The `NSWorkspace.willPowerOffNotification` handler (`installLifecycleSnapshotObserversIfNeeded`)
  also saves with `cleanShutdown: true` -- at that moment the system is going down in an orderly
  way. If the user cancels the shutdown, the next periodic autosave overwrites it with `false`
  again, so there is no staleness risk from marking it clean up front.
- Every other save path (autosave ticks, resign-active, window-unregister, startup
  post-restore) saves with `cleanShutdown: false`, the parameter's default.

There is no UI prompt in this pass -- the flag is surfaced read-only via `snapshot.list`, for a
human or an agent to inspect, not acted on automatically.

### Manual restore

`snapshot.list` and `snapshot.restore` (v2 socket methods) and `programa snapshot
list`/`restore` (CLI) read the history archive independently of the live snapshot file.
Restoring never touches an already-open window -- it only ever creates new windows, one per
window entry in the archived snapshot, reusing the exact same window-construction path
(`AppDelegate.createMainWindow(sessionWindowSnapshot:)`) that startup restore already uses for
every window beyond the primary one.

## Non-goals

- **No UI prompt or automatic recovery banner.** A user who wants their layout back runs
  `programa snapshot restore`; nothing pops up unprompted.
- **No cross-boot escrow of live terminal processes.** This is a *layout* (window/workspace/pane
  geometry, cwd, titles) restore, not a process-survival mechanism -- that already exists
  separately as detached sessions (`Sources/SessionEscrow.swift`) and is unrelated to this
  feature.
- **No automatic pruning of the live snapshot's rotation cadence beyond "once per launch."** The
  history archive is not a substitute for the debounced autosave; it exists purely to catch the
  moment right before the live file would otherwise be overwritten with no backup.
- **No cross-bundle-identifier merging.** Tagged dev builds and the release build share the
  `session-history/` directory (filenames are suffixed with their own bundle id), but pruning
  and listing treat the directory as one pool, not scoped per bundle id.

## Method spec (`snapshot.list`, `snapshot.restore`)

| Method | Params | Result | Errors |
|---|---|---|---|
| `snapshot.list` | `{}` | `{ snapshots: [ { id, saved_at, created_at, clean_shutdown, window_count, workspace_count, panel_count } ] }`, newest first | -- (unreadable/undecodable files are skipped, never fail the whole list) |
| `snapshot.restore` | `{ id?: string }` (absent or `"latest"` -> newest archived entry) | `{ restored: { windows, workspaces, panels } }` | `not_found` (no archived snapshot / unknown id / no windows to restore), `version_mismatch` (archived `version` does not match `SessionSnapshotSchema.currentVersion`) |

`id` is the archived file's name without its `.json` extension (`<timestamp>-<bundleId>`),
exactly as returned by `snapshot.list`.

## CLI spec

### `programa snapshot list [--json]`

One line per archived snapshot, newest first: id, saved-at, `clean`/`unclean`/`unknown`
(reflecting `clean_shutdown`), and window/workspace/panel counts.

### `programa snapshot restore [<id>|latest]`

Defaults to `latest` when the argument is omitted. Prints `OK restored windows=<n>
workspaces=<n> panels=<n>` (or the full JSON result with `--json`).

## Rotation + clean-shutdown semantics summary

- Rotation: once per launch, unconditional on `shouldAttemptRestore()`, copy (not move),
  duplicate-skip via byte comparison against the newest entry, prune to 10 newest.
- Clean shutdown: `true` from `applicationShouldTerminate`/`applicationWillTerminate` and the
  `willPowerOffNotification` handler; `false` from every other save path; `nil` only for
  pre-existing files that predate the field.
