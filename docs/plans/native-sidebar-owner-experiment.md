# Native Sidebar Owner Experiment

Status: **NO-GO for implementation or adoption on 2026-08-14.**

This plan records the 2026-08-14 AppKit audit gate. The production sidebar
stays on the existing SwiftUI scroll and reorder path. No native-owner
performance claim exists because no controlled A/B run has been completed.

## Current blocker

`TabItemView` is both the row renderer and the interaction owner. Its body
installs the internal drag source, sidebar and Bonsplit drop destinations,
selection tap, context menu, and accessibility reorder actions. Its drop
delegate also drives the existing 60 Hz autoscroll controller. The sidebar's
empty-area view owns the remaining internal and external drop destinations.

Putting the unchanged row in `NSTableView` or `NSCollectionView` would leave
SwiftUI as the drag/drop owner. Adding native delegates at the same time would
create two competing lifecycle owners. A wrapper that keeps the five-event
failsafe monitor and the timer active is not the native-owner experiment that
AK3 requires.

The same boundary blocks an exact row-body counter. A counter outside the
hosted row measures wrapper creation, not whether `TabItemView.equatable()`
skipped the child body.

## Required interaction seam

The prototype may begin only after a narrow `TabItemView` interaction seam is
approved. The seam must:

1. Preserve the row's visual subtree, precomputed inputs, `Equatable`
   implementation, and `.equatable()` call site unchanged.
2. Preserve the SwiftUI context menu and accessibility content/actions.
3. Allow DEBUG native mode to omit only `.onDrag`, both `.onDrop` handlers,
   and `.onTapGesture` from the row.
4. Extract the current command-click and shift-range selection algorithm into
   one shared policy used by both owners.
5. Add a DEBUG-only, disabled-by-default body counter inside the row. Disabled
   profiling must add no release work and no allocation to the typing path.

Production and DEBUG builds must continue to select the SwiftUI owner by
default.

## Native owner responsibilities

The DEBUG-only native variant should use `NSTableView` or `NSCollectionView`
and host the existing SwiftUI row in `NSHostingView`. It must exclusively own:

- selected indexes and synchronization with `selectedTabIds` and the active
  workspace;
- internal sidebar and external Bonsplit pasteboard types;
- drag-session start, cancellation, app-resign cleanup, validation, and drop
  completion;
- native edge autoscroll;
- row and empty-area drop targeting, including end-of-list insertion;
- keyboard focus and navigation;
- variable row-height invalidation; and
- accessibility selection and reorder behavior.

Native mode must not create or start `SidebarDragFailsafeMonitor`,
`SidebarDragAutoScrollController`, or the SwiftUI empty-area drop handlers.

## Parity gate

Before measurement, both variants must pass the same manual script for:

- click, command-click, and shift-range selection;
- active-workspace synchronization;
- reorder before and after a row, at the end, and over empty space;
- pinned-boundary rules and multi-row reorder;
- Bonsplit transfers into a row and empty space;
- context menus for single and multiple selected workspaces;
- keyboard navigation, first-responder restoration, and window switching;
- VoiceOver labels, selection, and reorder actions;
- mouse-up, Escape, app-resign, and window-close drag cancellation;
- live sidebar-width changes; and
- backdrop and non-backdrop sidebar layouts.

Any mismatch keeps the native path NO-GO.

## Measurement protocol

Run the same scripted session for each variant at 4, 20, and 48 workspaces.
Use multiple repetitions with a unique session and repetition identifier. Write
raw JSONL records to the tagged app's debug-log directory; each record must
include:

- variant, workspace count, session ID, repetition, monotonic timestamp, and
  operation;
- raw typing-delay/duration samples used for p95 and p99;
- main-run-loop stall duration samples;
- `getrusage` user/system CPU deltas for the measured interval;
- row construction and `TabItemView.body` update counts;
- mouse-down-to-selection latency; and
- drag-start-to-drop-or-cancel latency and outcome.

Use the existing `TypingProfiler`, `CACurrentMediaTime`, debug log, run-loop,
and stress-workspace facilities. The Sidebar Debug window should expose the
selected variant, workspace count, repetition/session state, and the raw log
path. Percentiles must be computed from saved samples, not emitted without the
underlying data.

## Adoption gate

Native ownership remains experimental unless repeated 4/20/48 runs show a
material improvement in the targeted lifecycle or measured latency without a
regression in any required metric or parity case. Reviewers must evaluate the
raw samples and scripts before changing the production default. If results are
neutral, noisy, or behaviorally worse, delete the prototype and keep the
existing SwiftUI owner.
