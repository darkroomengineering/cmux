# Main-window AppKit ownership plan

Status: planned, gated behind lifecycle proof

## Outcome

Every Programa main window should eventually have one `NSWindowController` owner and one
Programa-specific `NSWindow` subclass. SwiftUI should remain the root-content system through
`MainWindowHostingView`. This change is about deterministic window lifecycle and narrower event
ownership, not a claim that AppKit draws ordinary content faster.

The current release must not switch the primary window away from `WindowGroup`. The first window
still depends on SwiftUI scene restoration and command installation, while secondary windows are
created by `AppDelegate.createMainWindow`. Moving the first window before the contracts below are
executable would trade known duplication for unbounded restoration and activation risk.

## Non-goals

- Do not move or hide AppKit's standard traffic-light buttons.
- Do not replace the terminal or browser portal system.
- Do not rewrite command-palette rows, settings, forms, or other state-driven content in AppKit.
- Do not remove the application-level event hook until its app-wide responsibilities are separated
  from window-specific routing.
- Do not report a performance gain without repeated before-and-after measurements.

## Functional DAG

```text
MW1 lifecycle contract inventory
  -> MW2 MainWindowCoordinator extraction
      -> MW3 ProgramaMainWindow for secondary windows
          -> MW4 replace window-specific global exchanges
              -> MW5 primary-window restoration harness
                  -> MW6 AppKit-owned primary window
                      -> MW7 delete WindowAccessor ownership path
                          -> MW8 remove registry compensation made unreachable
```

Each node must merge independently. A later node cannot begin while its predecessor has an open
correctness failure.

## MW1: executable lifecycle contracts

Capture the current behavior before moving ownership:

- first launch with and without restorable state;
- close and reopen the last main window;
- create, close, and restore multiple main windows;
- key/main transitions without focus theft;
- enter and leave fullscreen with titlebar accessories intact;
- route SwiftUI commands to the correct window context;
- retain the key-window fallback and `didBecomeKey` self-heal when `occlusionState` is temporarily
  wrong during creation;
- preserve session identifiers and window-to-`TabManager` routing across restoration.

Use runtime window objects, responder state, and restored sessions as assertions. Do not test source
shape, project files, or the presence of a class name.

## MW2: extract `MainWindowCoordinator`

Move the existing main-window registration, overlay installation, accessory attachment, context
reindexing, and close-observer lifecycle out of `AppDelegate` into one coordinator. Keep both current
window creation paths calling the coordinator. This stage changes ownership boundaries without
changing which object creates the first window.

The coordinator must remain idempotent because the current scene-window accessor and secondary
creation path can both reach configuration. Its public surface should accept an existing `NSWindow`,
the window identifier, `TabManager`, and `SidebarState`; feature-specific views should not leak into
it.

## MW3: introduce `ProgramaMainWindow`

Use the subclass for manually created secondary main windows first. Keep standard AppKit style-mask,
close, minimize, zoom, titlebar, fullscreen, and restoration behavior. The subclass should own only
Programa-specific responder and event overrides that currently apply to all `NSWindow` instances.

Settings, import, update, debug, and auxiliary panels must remain ordinary `NSWindow` instances and
must stop receiving main-window-only behavior after this stage.

## MW4: retire window-specific global exchanges

Move `makeFirstResponder`, `sendEvent`, and `performKeyEquivalent` behavior into
`ProgramaMainWindow` one method at a time. Keep the existing keyboard fast path: do not restore a
hit test for key-down, key-up, or flags-changed events. Leave the `NSApplication.sendEvent` hook in
place until its app-wide and main-window responsibilities have separate owners.

For each override, prove parity on secondary windows before expanding its use. The old exchanged
implementation remains the fallback for the primary window until MW6.

## MW5: primary-window restoration harness

Add a debug or test-only creation seam that can construct the first main-window context through the
coordinator without ordering it on screen. The harness must round-trip the same restoration payload,
window identifier, `TabManager`, and command-routing context as `WindowGroup`.

This is the go/no-go gate for replacing scene ownership. Stop if SwiftUI commands, restoration,
activation policy, or close/reopen behavior cannot be exercised through the seam.

## MW6: switch the primary window

Create the first main window through the same `MainWindowController` path as later windows and host
`ContentView` in `MainWindowHostingView`. Preserve SwiftUI command installation and Settings scene
behavior explicitly; do not keep a hidden or duplicate scene window as a compatibility shim.

The change ships only when the MW1 suite is green and a tagged app passes launch, restore,
multiwindow focus, fullscreen, and close/reopen checks on the supported macOS versions.

## MW7: delete `WindowAccessor` ownership work

After every main window is controller-owned, remove the `WindowAccessor` path that discovers and
configures main windows after SwiftUI attachment. Keep `WindowAccessor` only where it still provides
an unrelated view-local service. Delete duplicate registration and asynchronous window-derived state
writes that become unreachable.

## MW8: simplify registry recovery

Remove orphan sweeps, identifier reindexing, and fallback lookup branches only when runtime coverage
proves the unified controller makes them unreachable. Keep recovery that protects external AppKit
lifecycle behavior rather than compensating for the former dual ownership paths.

## Verification and measurements

Every stage requires:

1. the focused runtime lifecycle tests for that stage;
2. a tagged Debug build and real-window interaction pass;
3. existing command-palette, titlebar, sidebar-resize, terminal, browser, and multiwindow suites;
4. no new main-thread work in keyboard event paths;
5. repeated A/B latency samples before any performance statement.

Roll back the current stage if it needs a second window owner, delayed frame writes, forced standard
button state, or a new global `NSWindow` exchange to work.
