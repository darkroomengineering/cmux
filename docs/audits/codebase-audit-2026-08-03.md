# Codebase adversarial audit — 2026-08-03

Scope: runtime cost (startup, RAM, idle CPU, keystroke hot paths) plus the expectation-gap hunt —
where the code does not do what its own comments, schema, settings, or docs promise.

Companion to the same-day nuclear-review (runtime-cost findings N1–N11). This audit hunts honesty,
not maintainability. Findings here do not repeat that report.

## Summary

| ID | Sev | Area | Issue | Location | Status |
|---|---|---|---|---|---|
| H1 | High | Process lifecycle | Escrow holder process has no exit path; leaks a full app-binary copy per abnormal exit | `Sources/SessionEscrow.swift:872-902` | CONFIRMED |
| H2 | High | Settings | Three documented `app.*` settings have zero readers anywhere | `Resources/settings.schema.json:44-73` | CONFIRMED |
| H3 | High | Settings | Two `browser.*` schema keys never match the parser's key names | `settings.schema.json:291-300` vs `ProgramaSettingsFileStore.swift:617-622` | CONFIRMED |
| M1 | Med | Settings | Port base/range cached in `static let`; mid-session changes ignored despite UI implying otherwise | `Sources/TerminalSurface.swift:184-191` | CONFIRMED |
| M2 | Med | Naming/boundary | A type named `…DebugStore` is a load-bearing dependency of non-debug Settings styling | `Sources/SettingsView.swift:2170` | CONFIRMED |
| M3 | Med | Socket policy | Five telemetry *read* commands block on `DispatchQueue.main.sync` | `Sources/TerminalController+Telemetry.swift:653,739,802,1013,1034` | CONFIRMED |
| M4 | Med | Doc drift | CLAUDE.md documents `cd programad && zig build`; no such directory, daemon is Go | `CLAUDE.md:71-74` | CONFIRMED |
| M5 | Med | Doc drift | CLAUDE.md focus allowlist omits six methods the code actually allows | `Sources/TerminalController.swift:120-138` | CONFIRMED |
| L1 | Low | Localization | Bare user-facing string literals | `TabItemView.swift:422,636` | CONFIRMED |

## Remediation status (updated same day)

- **H1** — shipped in PR #237: reaper + TTL (1h) + idle exit, plus fd-reuse and exit/accept race
  fixes. Claim/renew reconciliation was built, then **dropped before shipping**: cross-model review
  confirmed a 120s time-based reconcile destroys sessions that `programa snapshot restore` can
  legitimately reattach at any later time (`v2SnapshotRestore` → `createMainWindow` →
  `attemptSessionReattach`). Any automatic early drop conflicts with manual snapshot recovery —
  the durable design needs explicit claims, not clocks. TTL remains the leak bound; tracked as an
  issue.
- **N6 addendum** — `STRIP_INSTALLED_PRODUCT` alone is inert under CI's plain `xcodebuild build`;
  `DEPLOYMENT_POSTPROCESSING = YES` was required to make it fire. Verified locally: 110,546 local
  symbols → 0, binary 57 MB → 33 MB.
- **M4** — shipped in PR #237 (CLAUDE.md daemon section rewritten).
- **H2, H3** — in progress on `perf/audit-backlog`.
- **M2** — in progress on `perf/audit-backlog` (store relocation + `#if DEBUG` gating).
- **M1, M3, M5, L1** — open, not yet scheduled.
- Correction to the companion nuclear-review discussion: the "CVDisplayLink = 69% of activity"
  figure quoted in chat was a misread of `sample(1)` output (thread presence, not CPU). The
  occlusion finding stands on the unwired-`ghostty_surface_set_occlusion` evidence; measured
  idle-visible CPU is ~6%.

## Findings

### H1 — The escrow holder never exits

`SessionEscrowHolder.run(socketPath:) -> Never` ends in an unconditional server loop:

```swift
while true {
    let clientFD = accept(listenFD, nil, nil)
    guard clientFD >= 0 else { continue }
    Thread.detachNewThread { serve(connectionFD: clientFD) }
}
```

The file's **only two `exit()` calls (lines 881, 887) are both startup guards** — redundant-holder
detection and bind failure. Once the loop is entered there is no exit condition: not "registry
empty", not "no connections", not an idle timeout. `AppDelegate.applicationWillTerminate`
(`Sources/AppDelegate.swift:1520-1535`) tears down the autosave timer, TerminalController,
MobileBridgeListener, VSCodeServeWebController and BrowserProfileStore — and never touches escrow.

A holder is spawned for **every** terminal surface, not only on update relaunch:
`attemptSessionEscrow` runs unconditionally from `resolveSessionWALIdentity`
(`Sources/TerminalSurface.swift:1291,1364-1381`), gated only by `SessionMachineryGate.isUnitTesting`.
Each holder is a `posix_spawn` of a second full copy of the app binary (AppKit + SwiftUI +
GhosttyKit linked in) with `POSIX_SPAWN_SETSID`.

**Live evidence (this machine, 2026-08-03):** three orphan holders with `ppid=1`, oldest running
since Jul 31 (3d 01h), plus 12 orphaned `login`/zsh shells whose uptimes pair off exactly against
them. ~42 MB resident and ~26 pty masters held by processes whose app exited days ago. One of the
three was created by a throwaway tagged test build and survived deletion of the app, its
DerivedData, and its socket file — killing the app does not reap the holder.

Scope note: CPU is 0.0% on all of them. This is an fd/pty/memory leak, not a CPU burn.
`kern.tty.ptmx_max` is 511 with 52 allocated, so exhaustion is not imminent — but the leak is
monotonic and never drains.

Direction: give the holder an exit condition (registry empty + no live connections for N seconds),
and reap it explicitly from `applicationWillTerminate`.

### H2 — Three settings documented but never read

`Resources/settings.schema.json` documents `app.keepWorkspaceOpenWhenClosingLastSurface` (44-48),
`app.focusPaneOnFirstClick` (49-53), `app.renameSelectsExistingName` (69-73), each with a
behavioural description. Grep across `Sources/` finds zero matches for these names or any
synonym. `ProgramaSettingsFileStore.parseAppSection` (317-354) handles only `appearance`,
`newWorkspacePlacement`, `minimalMode`, `preferredEditor`, `reorderOnNotification`,
`warnBeforeQuit`, `commandPaletteSearchesAllSurfaces`.

Scenario: a user adds `"focusPaneOnFirstClick": false` to stop first-click focus steal. The key
validates against the schema, no warning is logged, and nothing changes — because no code reads it.

### H3 — Browser settings: schema and parser disagree on the key name

Schema documents `browser.openTerminalLinksInCmuxBrowser` and
`browser.interceptTerminalOpenCommandInCmuxBrowser` (pre-rebrand "Cmux" naming). The parser
(`ProgramaSettingsFileStore.swift:617-622`) reads only
`openTerminalLinksInProgramaBrowser` / `interceptTerminalOpenCommandInProgramaBrowser`.

Scenario: a user copies the key name from the schema, sets it to `false`, and links keep opening
in the embedded browser. The key is never inspected, so not even an invalid-key log fires.

### M1 — Port base/range snapshot once per process

```swift
static let sessionPortBase: Int = { … UserDefaults … }()   // TerminalSurface.swift:184-191
```

`static let` evaluates on first access — the first terminal surface created in the process — and
caches for the process lifetime. The Settings UI (`SettingsView.swift:1146`) says "New terminals
inherit these values", implying a live effect. Changing Port Base mid-session has no effect on
subsequent terminals until restart.

### M2 — A "Debug"-named type that non-debug code depends on

`SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to:for:)` is called from
`applyCurrentSettingsWindowStyle` in `Sources/SettingsView.swift:2170` — ordinary Settings window
styling, not debug UI. Five controllers in the same file are likewise referenced unguarded from
`Sources/ProgramaApp.swift:1122-1126,1165,1178,1265,1281`.

This was proven the hard way: wrapping `Sources/DebugWindows.swift` in `#if DEBUG` (the obvious
reading of "this file is debug-only") produced **15 Release compile errors**. The name promises
the file is debug-scoped; the dependency graph says otherwise. The nuclear-review finding that
this file is dead weight in Release remains true, but the fix requires splitting the genuinely
non-debug store out first, not a blanket wrap.

### M3 — Telemetry read commands block the main thread

CLAUDE.md: "If adding a new socket command, default to off-main handling." The write side is
compliant (`v2ScheduleTelemetryMutation`). Five read-side counterparts call `v2MainSync`
(`TerminalController.swift:2058-2068`, a real `DispatchQueue.main.sync`) from per-connection
detached threads:

`v2WorkspaceListStatus:653`, `v2WorkspaceListLog:739`, `v2WorkspaceSidebarState:802`,
`v2WorkspaceListMetaBlocks:1013`, `v2WorkspaceResetSidebar:1034`.

A sixth (`v2WorkspaceClearMetaBlock:993`) carries an explicit comment justifying it as rare; the
other five do not. No high-frequency caller exists today, so impact is PLAUSIBLE rather than
proven — but any external tool polling `sidebar_state` for a dashboard would stall the main thread
in exactly the way this policy was written to prevent.

### M4 / M5 — Documentation drift

- CLAUDE.md:71-74 instructs `cd programad && zig build -Doptimize=ReleaseFast`. There is no
  `programad/` directory; the remote daemon is `daemon/remote/cmd/programad-remote`, and it is
  **Go** (19 `.go` files, 0 `.zig` files). The documented build command cannot succeed.
- `focusIntentV2Methods` (`TerminalController.swift:120-138`) additionally allows `review.open`,
  `worktree.create`, `worktree.open`, `debug.command_palette.toggle`, `debug.notification.focus`,
  `debug.app.activate` — none in CLAUDE.md's written allowlist. The policy grew; the doc did not.

### L1 — Bare user-facing strings

`Sources/TabItemView.swift:422` (`Text("\(unreadCount)")`) and `:636`
(`Text("\(pullRequest.label) #\(pullRequest.number)")`). Small scale; a spot-check, not exhaustive.

## Upheld contracts

- **Socket focus policy** — a real allowlist checked once at dispatch entry, with non-allowlisted
  commands gated through `v2FocusAllowed()` so a caller-supplied `focus` param cannot override.
- **No app-level display link / manual draw loop** — zero `ghostty_surface_draw` calls; the only
  `CVDisplayLink`s are ghostty's per-surface vsync and Bonsplit's divider-drag animator.
- **Terminal find layering** — `SurfaceSearchOverlay` is mounted from `GhosttySurfaceScrollView`,
  with an explicit warning comment against the SwiftUI path in `TerminalPanelView.swift:50`.
- **Feature toggles genuinely stop work** — `MobileBridge` off stops both listener and push;
  `AgentScreenDetection` off short-circuits its tick to a plain sleep.

## Considered and rejected

- **Bonsplit `SplitAnimator` leak** — every path that empties `animations` calls `stopIfNeeded()`
  in the same turn, including the weak-ref sweep. No leak.
- **PortScanner `agentScanTimer` leak** — a closed workspace is dropped on the next 2s tick via
  `agentPIDsProvider`; worst case a ~2s tail, not permanent.
- **SessionWALStore drain/frame timers** — all five `unregister()` call sites run on the same
  serial queue as `startWriter`, and `stopWriter()` always calls `stopTimersIfIdle()`.
- **"Zig daemon" idle cost** — N/A. No resident Zig daemon exists; the Go remote daemon is spawned
  per SSH connection and exits on stdin EOF.
- **`GhosttyConfig.scrollbackLimit` "parsed but never wired"** — false. It mirrors a ghostty
  config-file key that ghostty loads itself; the Programa-side reader is a line-count estimate by
  design. Recorded so this is not re-litigated.

## Open questions

1. Should the escrow holder self-terminate on an idle timeout, or be reaped explicitly at app quit?
   The current design intentionally outlives the app — the exit condition is a product decision.
2. Are the three phantom `app.*` settings unimplemented features or removed ones? Delete from the
   schema, or implement?
3. `browser.*` key mismatch — accept both names for back-compat, or fix the schema only?

## Not covered

Shortcut-policy conformance (whether every branch of `handleCustomShortcut` consults
`KeyboardShortcutSettings`), and the sweep for performance-claiming comments that the code no
longer honors. Both ran out of budget; neither was started rather than partially done.
