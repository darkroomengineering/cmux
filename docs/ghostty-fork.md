# Ghostty Fork Changes (Darkroom Engineering/ghostty)

This repo uses a fork of Ghostty for local patches that aren't upstream yet.
When we change the fork, update this document and the parent submodule SHA.

## Fork update checklist

1) Make changes in `ghostty/`.
2) Commit and push to the Darkroom Engineering ghostty fork.
3) Update this file with the new change summary + conflict notes.
4) In the parent repo: `git add ghostty` and commit the submodule SHA.

## Current fork changes

Current Programa pinned fork head: `96316fc50`, on fork `main`. It contains
the PTY tee, PTY/process accessors, surface revival, occluded-render throttle,
renderer realization API, bounded screen export, precision scrolling, and the
temporary-directory handle fix. The parent previously pinned `6772a8884`
directly on the temporary-directory feature branch. Although the historical
Programa commits remained reachable through retain-ancestry merges, their
accessor and revival changes were absent from the resulting fork-main tree.
`96316fc50` reconciles those required APIs onto the actual fork `main` tree.

The section 8 occluded-render skip (`c25020f99`, branch
`perf/occluded-update-frame-skip`, retain-ancestry merge `363d56e5d` on fork
`main`) was pinned on August 4, 2026 and REVERTED the same day. The initial
write-up attributed the CI failures to a Swift-side window-teardown race
masked by incidental render-thread serialization; closer reading of the
renderer code found the actual mechanism instead: on CI's virtual display
every surface is permanently occluded, and the hard skip left
`ghostty_surface_read_text` (used by the app's socket event-subscription
polling; locks `renderer_state.mutex`) hanging forever, because
`scrollbar_dirty` is set inside `updateFrame` but only cleared inside
`drawFrame`, and `drawFrame` is *also* gated off while invisible — the skip
left that state machine with no live half. (A separate, unrelated
use-after-free via stale surface userdata in the `.scrollbar` mailbox path
was also found and fixed app-side during this investigation.)

Section 8 was re-landed on August 5, 2026 as a throttle instead of a hard
skip (`08bac45e9`, branch `perf/occluded-update-frame-throttle`): call
`updateFrame` on every wakeup while visible (unchanged from upstream), but
at most once per 250ms while occluded, so anything gated behind
`updateFrame` — including the scrollbar handshake above — keeps making
forward progress instead of stalling. See section 8 below for the full
rationale. The prebuilt release and checksum pin for `c25020f99` are no
longer relevant; `08bac45e9` has its own pin.

### 1) macOS display link restart on display changes

- Commit: `05cf31b38` (macos: restart display link after display ID change)
- Files:
  - `src/renderer/generic.zig`
- Summary:
  - Restarts the CVDisplayLink when `setMacOSDisplayID` updates the current CGDisplay.
  - Prevents a rare state where vsync is "running" but no callbacks arrive, which can look like a frozen surface until focus/occlusion changes.

### 2) macOS resize stale-frame mitigation

The resize commits are grouped by feature because they touch the same stale-frame replay path and
tend to conflict together during rebases.

- Commits:
  - `a3588ac53` (macos: reduce transient blank/scaled frames during resize)
  - `9ba54a68c` (macos: keep top-left gravity for stale-frame replay)
- Files:
  - `pkg/macos/animation.zig`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/renderer/Metal.zig`
  - `src/renderer/generic.zig`
  - `src/renderer/metal/IOSurfaceLayer.zig`
- Summary:
  - Replays the last rendered frame during resize and keeps its geometry anchored correctly.
  - Reduces transient blank or scaled frames while a macOS window is being resized.

### 3) OSC 99 (kitty) notification parser

- Commits:
  - `2033ffebc` (Add OSC 99 notification parser)
  - `a75615992` (Fix OSC 99 parser for upstream API changes)
- Files:
  - `src/terminal/osc.zig`
  - `src/terminal/osc/parsers.zig`
  - `src/terminal/osc/parsers/kitty_notification.zig`
- Summary:
  - Adds a parser for kitty OSC 99 notifications and wires it into the OSC dispatcher.
  - Adapts the parser to upstream's newer capture API so the Programa OSC 99 hook survives the March 30 upstream sync.

### 4) Programa theme picker helper hooks

- Commits:
  - `1da7281fd` (Add Programa theme picker helper hooks)
  - `ea482b73e` (Fix Programa theme picker preview writes)
  - `c7ab66056` (Improve Programa theme picker footer contrast)
  - `c49f69f7b` (Respect system theme in Programa picker)
  - `599b0ff43` (Skip theme detection in Programa picker)
  - `b75388d95` (Match Ghostty theme picker startup)
  - `f985d2d04` (Harden Programa theme override writes)
- Files:
  - `build.zig`
  - `src/cli/list_themes.zig`
  - `src/main_ghostty.zig`
- Summary:
  - Adds a `zig build cli-helper` step so Programa can bundle Ghostty's CLI helper binary on macOS.
  - Lets `+list-themes` switch into a Programa-managed mode via env vars, writing the Programa theme override file and posting the existing Programa reload notification for live app-wide preview.
  - Keeps the preview UI readable in light mode, matches upstream picker startup behavior, and hardens writes to the Programa-managed theme override file.

### 5) Color scheme mode 2031 reporting

- Commits:
  - `2be58ee0e` (Fix DECRPM mode 2031 reporting wrong color scheme)
  - `74709c29b` (Send initial color scheme report when mode 2031 is enabled)
- Files:
  - `src/Surface.zig`
  - `src/termio/stream_handler.zig`
- Summary:
  - Keeps Ghostty's mode 2031 color-scheme response aligned with the surface's actual conditional state after config reloads.
  - Sends the initial DSR 997 report as soon as mode 2031 is enabled, which Programa relies on for immediate color-scheme awareness.

### 6) Keyboard copy mode selection C API

- Commit: `0b231db94` (Re-export Programa selection APIs removed from upstream)
- Files:
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
- Summary:
  - Restores `ghostty_surface_select_cursor_cell` and `ghostty_surface_clear_selection`.
  - Keeps Programa keyboard copy mode working against the refreshed Ghostty base after upstream removed those exports.

### 7) macos-background-from-layer config flag

- Commit: `ae3cc5d29` (Restore macOS layer background hook)
- Files:
  - `src/config/Config.zig`
  - `src/renderer/generic.zig`
- Summary:
  - Adds a `macos-background-from-layer` bool config (default false).
  - When true, sets `bg_color[3] = 0` in the per-frame uniform update so the Metal renderer skips the full-screen background fill.
  - Allows the host app to provide the terminal background via `CALayer.backgroundColor` for instant coverage during view resizes, avoiding alpha double-stacking.
  - Replays the layer-background restore on top of the refreshed Ghostty base so Programa keeps the resize-coverage fix after the upstream sync.

### 8) Occluded-surface frame-generation throttle

- Commit: `08bac45e9` (perf(renderer): throttle instead of skip frame generation for occluded surfaces), superseding the reverted `c25020f99` skip on branch `perf/occluded-update-frame-throttle`
- Files:
  - `src/renderer/Thread.zig`
- Summary:
  - `renderCallback` previously called `updateFrame` unconditionally on every wakeup (i.e. every PTY output burst), even for surfaces the app has told us are fully occluded. That call locks the terminal mutex, consumes dirty tracking, and rebuilds render state — the dominant idle-CPU cost for hidden-but-busy surfaces (e.g. background agent panes).
  - The first attempt at fixing this (`c25020f99`) hard-skipped `updateFrame` entirely while occluded. That broke anything with only half its state machine living inside `updateFrame`: `scrollbar_dirty` is set inside `updateFrame` (generic.zig) but only cleared inside `drawFrame`, and `drawFrame` is *also* gated off while invisible. On CI, where every surface is permanently occluded on the virtual display, this manifested as `ghostty_surface_read_text` (locks `renderer_state.mutex`; used by the app's socket event-subscription polling) hanging indefinitely.
  - The current implementation throttles instead of skipping: `updateFrame` still runs on every wakeup while visible (unchanged from upstream), and while occluded it runs at most once per `OCCLUDED_UPDATE_INTERVAL_MS` (250ms / 4Hz), tracked via a monotonic `std.time.Instant` timestamp on `Thread` that resets to `null` on the visible→occluded transition so the first occluded update fires immediately. PTY-burst wakeups for a busy hidden surface can arrive at 60-120Hz, so this is a ~95-98% reduction in frame-generation work — nearly all of the CPU win of the hard skip — while guaranteeing anything gated behind `updateFrame` keeps making forward progress.
  - `drainMailbox`'s `.visible` false→true transition still calls `renderer.markDirty()` to force one full rebuild at un-occlude, unchanged from the original skip implementation. Terminal-side dirty tracking is level-triggered (bits accumulate until consumed; dimensions/viewport compared directly), so this remains correctness-optional but cheap insurance against renderer-side cache staleness.
  - Merge gate for this fork branch is 3 consecutive green CI runs before it lands on fork `main` — the failure mode that motivated the throttle (CI hangs on an occluded virtual display) is probabilistic, not deterministic.

### 9) Offscreen renderer realization API

- Commits:
  - `858e257f0` (add `ghostty_surface_set_renderer_realized`)
  - `d39ba5d84` (return the renderer-mailbox enqueue result)
  - `5697db813` (make the enqueue non-blocking)
- Files:
  - `include/ghostty.h`
  - `src/apprt/embedded.zig`
  - `src/renderer/Thread.zig`
  - `src/renderer/message.zig`
- Summary:
  - Lets the embedder release an occluded surface's Metal swap chain and IOSurfaces while leaving its PTY, terminal state, and scrollback alive.
  - Recreates the renderer before the surface is shown again.
  - Uses a non-blocking mailbox push and reports whether it was enqueued, so Programa never stalls the main actor or advances its mirror state after a dropped message.

### 10) Programa session introspection and revival APIs

- Commit: `96316fc50` (reconcile Programa session APIs on fork main)
- Files:
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/termio/Exec.zig`
- Summary:
  - Restores read-only child PID, PTY path, and PTY master-fd accessors used by Programa's durable session machinery.
  - Restores surface revival through an existing PTY master fd and running child PID without taking ownership of or signaling that process.
  - Programa now uses the fork's newer `ghostty_surface_set_pty_tee_cb` callback for its session WAL. That callback runs before VT parsing and supersedes the older Programa-only output-tap API, so the obsolete output-tap export was intentionally not restored.
  - Reconciles the reachable historical feature lineage with the concrete fork-main file tree, which is what consumers and release artifacts actually build.
- Prebuilt framework:
  - Release: `xcframework-96316fc506f0015f6e8e3906b995e2c4aba23ebf`
  - Asset SHA-256: `0f12f0d6dd920ccfa49789eae1018be314344797894ef0aae7db3e90fc27a441`

The fork branch head is now `96316fc50` on fork `main`.

## Upstreamed fork changes

### cursor-click-to-move respects OSC 133 click-to-move

- Was local in the fork as `10a585754`.
- Landed upstream as `bb646926f`, so it is no longer carried as a fork-only patch.

### zsh prompt redraw follow-ups

- Were local in the fork as `8ade43ce5`, `0cf559581`, `312c7b23a`, and `404a3f175`.
- Dropped during the March 30, 2026 rebase because newer Ghostty prompt-marking changes on the refreshed base superseded these fork-only zsh redraw patches, so Programa no longer carries them separately.

### initial focus seeding and DECSET 1004 startup behavior

- Was local in the fork as `c19c82bfd`.
- Dropped from the current pinned fork head when Programa removed the corresponding
  app-side initial focus seed and went back to post-create focus sync.

## Merge conflict notes

These files change frequently upstream; be careful when rebasing the fork:

- `src/terminal/osc.zig`
  - OSC dispatch logic moves often. Re-check the integration points for the OSC 99 parser and keep
    the newer `capture`/`captureTrailing()` API usage intact.

- `src/terminal/osc/parsers.zig`
  - Ensure `kitty_notification` stays imported after upstream parser reorganizations.

- `src/cli/list_themes.zig`
  - Programa now relies on the upstream picker UI plus local env-driven hooks for live preview and restore.
    If upstream reorganizes the preview loop or key handling, re-check the Programa mode path and keep the
    stock Ghostty behavior unchanged when the Programa env vars are absent.

- `build.zig`
  - Upstream's new wasm/libghostty work touched the same build graph. Keep the Programa-only `cli-helper`
    step wired in without regressing the upstream `lib-vt` or wasm build paths.

- `include/ghostty.h`, `src/Surface.zig`, `src/apprt/embedded.zig`, `src/termio/Exec.zig`
  - Upstream removed Programa-used selection exports. Preserve the re-exported
    `ghostty_surface_select_cursor_cell` and `ghostty_surface_clear_selection` functions.
  - Preserve the child/PTY accessors and revival configuration described in section 10.
    If upstream changes subprocess ownership or watcher semantics, revived processes must
    remain non-owned: Programa may observe their exit but Ghostty must never signal them.
  - Prefer the current PTY tee callback over reintroducing the retired output-tap API.

- `src/renderer/generic.zig`
  - The `macos-background-from-layer` check sits next to the glass-style check in `updateFrame`.
    If upstream refactors the bg_color uniform update or the glass conditional, re-check that both
    paths still zero out `bg_color[3]` correctly.

- `src/Surface.zig`, `src/apprt/embedded.zig`, `macos/Sources/Ghostty/Surface View/SurfaceView.swift`
  - The initial `focused` plumbing has to stay aligned across the C config, embedded runtime surface,
    and macOS wrapper. If upstream refactors surface creation or post-create focus sync, re-check that
    background panes can start unfocused without synthesizing a focus-loss transition during creation.

- `src/renderer/Thread.zig`
  - The occluded-render throttle guards the ONLY `updateFrame` call site at our base
    (`renderCallback`). Upstream `main` has since added another caller (`renderNow`) plus more
    visibility-adjacent logic — on the next upstream sync, re-apply the same throttle (call on every
    wakeup while visible, at most once per `OCCLUDED_UPDATE_INTERVAL_MS` while occluded, using the
    `last_occluded_update` timestamp on `Thread`) to EVERY `updateFrame` call site, not just
    `renderCallback`. Do NOT go back to a hard `flags.visible` skip — see section 8 above for why
    that broke `ghostty_surface_read_text` polling on CI's permanently-occluded virtual display.
    Keep the `markDirty()` force on the occluded→visible transition in `drainMailbox`.

- `src/termio/stream_handler.zig`
  - Keep DECSET 1004 enablement side-effect free. xterm-compatible focus reporting should only emit
    `CSI I` / `CSI O` on actual focus transitions, not immediately when the mode is enabled.

If you resolve a conflict, update this doc with what changed.
