# Codebase Audit — 2026-08-31

**Verdict: REMEDIATED WITH ONE UPSTREAM BLOCKER.** The landing series resolves all 10 high-severity findings, 17 of 18 medium-severity findings, and the low-severity finding. M12 is complete for Sparkle; the Iroh update remains blocked by an invalid checksum in the latest stable upstream release rather than by local code.

Audit basis: `main` at `2097c7b795` on 2026-08-31. This was a read-only source audit. Vendored/generated code, the Ghostty submodule's internals, and dependency build products were excluded. No local tests or builds were run because the repository policy sends tests to CI/VM. Standalone Codex has no reliable Swift dead-code scanner here, so this report makes no claim that the repository is free of dead code. Team knowledge was unavailable because `KNOWLEDGE_REPO_PATH` was not reachable.

Remediation basis: the full uncommitted landing candidate built successfully with `./scripts/reload.sh --tag audit-fixes` on 2026-08-31. Local suites were not run, per repository policy; the regression suite is assigned to GitHub Actions in a red/green commit sequence. Structural CI budgets keep the five audited entry-point families below their pre-remediation combined line counts. The Iroh `v1.0.2-cmux.8` manifest declares SHA-256 `f9218939c1e8a74d1db77ea57fefc41a772e3f1e854925cb35b693495df6be9a`, while its published release asset reports `77bced2458c672e1c8d903561a6866a6ef7e29ec807068520cefd2832041bb29`. The only newer release, `v1.0.2-cmux.9-dev.1`, is explicitly prerelease, so the known-good `.3` pin remains until upstream publishes a corrected stable artifact.

## Summary

| ID | Severity | Area | Issue | Location | Status |
|---|---|---|---|---|---|
| H1 | HIGH | Structure | 48 production files exceed 1,000 lines; five entry points own several unrelated systems | `Sources/AppDelegate.swift:1` | RESOLVED |
| H2 | HIGH | CLI / protocols | Four hand-maintained clients disagree about protocol version, relay auth, and password auth | `daemon/remote/cmd/programad-remote/cli.go:50` | RESOLVED |
| H3 | HIGH | Remote execution | A predictable shared `/tmp` module is injected into every remote Claude Node process | `daemon/remote/cmd/programad-remote/agent_launch.go:393` | RESOLVED |
| H4 | HIGH | Remote bootstrap | Downloaded daemon files are used after URLSession invalidates their temporary URL; timeout state also races | `Sources/WorkspaceRemoteSessionController+DaemonInstall.swift:300` | RESOLVED |
| H5 | HIGH | Settings / startup | Positive but out-of-range port settings can overflow and trap when the first terminal starts | `Sources/TerminalSurface.swift:1300` | RESOLVED |
| H6 | HIGH | Settings / concurrency | Managed-settings callbacks can concurrently mutate unsynchronized directory-trust state | `Sources/ProgramaSettingsFileStore.swift:118` | RESOLVED |
| H7 | HIGH | Session restore | Snapshot bytes and recursive layout trees are fully decoded before reconstruction caps apply | `Sources/SessionPersistence.swift:388` | RESOLVED |
| H8 | HIGH | iOS RPC | The timeout helper cannot cancel a request parked in a checked continuation | `ios/ProgramaSpike/ProgramaSpike/BridgeConnection.swift:281` | RESOLVED |
| H9 | HIGH | CI supply chain | Mutable action tags execute with an OAuth secret and OIDC permission | `.github/workflows/claude.yml:21` | RESOLVED |
| H10 | HIGH | Go dependency | The remote daemon is built with the unsupported Go 1.22 language/toolchain contract | `daemon/remote/go.mod:3` | RESOLVED |
| M1 | MEDIUM | iOS framing | The iOS reader has no frame cap and rescans its growing buffer from byte zero | `ios/ProgramaSpike/ProgramaSpike/BridgeConnection.swift:388` | RESOLVED |
| M2 | MEDIUM | iOS identity | The long-lived Iroh identity and pairing ticket are stored in UserDefaults | `ios/ProgramaSpike/ProgramaSpike/SecretKeyStore.swift:3` | RESOLVED |
| M3 | MEDIUM | Browser security | Installed extensions receive every requested permission and host match forever, without consent | `Sources/Panels/BrowserExtensionManager.swift:111` | RESOLVED |
| M4 | MEDIUM | Input bounds | Browser downloads, history, VS Code output, and review diffs read untrusted/unbounded data before caps | `Sources/Panels/ProgramaWebView.swift:1158` | RESOLVED |
| M5 | MEDIUM | Session escrow | Holder election probes and binds separately, so a second holder can unlink the first holder's live socket | `Sources/SessionEscrow.swift:1288` | RESOLVED |
| M6 | MEDIUM | Process execution | Three near-identical subprocess runners duplicate timeout, pipe, kill, and decoding policy | `Sources/GitMetadataProber.swift:495` | RESOLVED |
| M7 | MEDIUM | iOS CloudKit | A local boolean permanently suppresses subscription repair after account changes or server deletion | `ios/ProgramaSpike/ProgramaSpike/CloudKitPush.swift:19` | RESOLVED |
| M8 | MEDIUM | iOS diagnostics | Production returns the first relay path although the validated spike waits for path settlement | `ios/ProgramaSpike/ProgramaSpike/PathClassifier.swift:42` | RESOLVED |
| M9 | MEDIUM | Setup | Setup accepts any Zig although Ghostty requires exactly the 0.16 line | `scripts/setup.sh:12` | RESOLVED |
| M10 | MEDIUM | Release tooling | The TestFlight script replaces the user's Keychain search list and never restores it | `scripts/build-ios-testflight.sh:55` | RESOLVED |
| M11 | MEDIUM | iOS structure | CmuxIrohTransport is linked but unused while a completed spike remains a divergent second implementation | `ios/ProgramaSpike/project.yml:5` | RESOLVED |
| M12 | MEDIUM | Dependencies | Sparkle and the Iroh fork miss released security/reliability fixes | `GhosttyTabs.xcodeproj/project.pbxproj:2236` | PARTIAL — IROH UPSTREAM BLOCKED |
| M13 | MEDIUM | Build scripts | App discovery is copied across scripts with conflicting stale-build selection | `scripts/reload.sh:324` | RESOLVED |
| M14 | MEDIUM | CLI | `programa race` waits for Git before draining stdout and can deadlock on a large ref list | `CLI/programa.swift:5877` | RESOLVED |
| M15 | MEDIUM | tmux compatibility | `wait-for` uses a shared predictable `/tmp` path and ignores write/remove failures | `daemon/remote/cmd/programad-remote/tmux_waitfor.go:10` | RESOLVED |
| M16 | MEDIUM | Remote process | Old relay stderr callbacks can append after teardown and contaminate the next relay's diagnostic buffer | `Sources/WorkspaceRemoteSessionController+ConnectionOrchestration.swift:262` | RESOLVED |
| M17 | MEDIUM | Notifications | User-notification delegate callbacks touch AppKit/model state without an explicit main-actor hop | `Sources/AppDelegate.swift:10301` | RESOLVED |
| M18 | MEDIUM | iOS reconnect | A failed retry can clear the only reconnect task after the phase consumer declines to schedule another | `ios/ProgramaSpike/ProgramaSpike/AppStore.swift:276` | RESOLVED |
| L1 | LOW | iOS docs / UX | Pairing recovery tells users to use controls that were removed | `ios/ProgramaSpike/ProgramaSpike/PairConnectView.swift:108` | RESOLVED |

## System map

```text
macOS app
  AppDelegate / ProgramaApp
    -> windows + workspaces + panels
    -> TerminalController JSON-RPC socket
    -> session snapshots / WAL / escrow
    -> browser, extensions, downloads, history
    -> remote SSH session controller

clients of the socket contract
  CLI/programa.swift -------- local Swift client
  CLI-MCP/* ----------------- MCP adapter
  programad-remote cli.go --- remote Go client
  MobileBridge -------------- Iroh relay for iOS

delivery
  setup/reload scripts -> GhosttyKit -> Xcode
  CI -> release workflow -> signed/notarized rolling release
  iOS TestFlight workflow -> ProgramaSpike + widgets
```

The principal ownership problem is that the socket contract, subprocess lifecycle, bounded-input policy, and remote-auth framing have no single source of truth. Each consumer reimplements enough of the contract to drift independently.

### Expectation gaps

- Expected every advertised remote CLI command to use the only supported socket protocol; found six v1 commands whose server always returns `v1_removed`, while the CLI exits zero.
- Expected `programa-mcp` to work whenever Programa's documented socket modes work; found no `auth.login` flow for password mode.
- Expected the Swift and Go relay clients to authenticate to the same server; found `cmux-relay-auth` in Swift and `programa-relay-auth` in the server and Go client.
- Expected positive port settings to be valid ports; found no upper-bound or overflow validation.
- Expected “New terminals inherit these values” to mean settings apply to new terminals; found process-lifetime `static let` caching.
- Expected a 15-second mobile request timeout to return in 15 seconds; found a task-group child that cannot be cancelled until teardown, while teardown waits for the helper.
- Expected the shipped iOS target to have replaced its “spike-grade” key storage; found TestFlight automation around a UserDefaults identity.
- Expected setup to reject an incompatible Zig before an expensive Ghostty build; found presence-only checks.

## Code-Judo opportunities

### J1 — Make the JSON-RPC contract the product boundary, not copied client code

Delete `protoV1`, the six v1 command specs, and the v1 executor. Define methods, parameter names, auth handshake identifiers, and error codes once, then generate or share thin Swift/Go/MCP client bindings. This removes H2's three independent failures and makes remote/local behavior mechanically comparable.

### J2 — One bounded process runner, one bounded byte-reader policy

Extract the already-correct process/pipe lifecycle into one owner used by Git metadata, review diffs, worktrees, and `race`. Separately, make byte limits part of the reader API rather than caller convention. Port the Mac mobile reader to iOS instead of maintaining an inlined cousin. This deletes M1, M4, M6, and M14's recurring failure shapes rather than patching each call site.

### J3 — Treat iOS as a production client or remove it from the shipping graph

The repository simultaneously calls the target a spike, auto-ships it to TestFlight, links an unused transport package, and keeps a second executable spike as reference code. Promote one implementation: Keychain identity, cancellable requests, bounded framing, settled path classification, subscription reconciliation, and tests. Then remove the compiled Cmux dependency and completed executable spike. If it is genuinely experimental, remove auto-shipping instead.

### J4 — Split entry-point coordinators by owned lifecycle

Do not continue adding extensions to `AppDelegate`, `CLI/programa.swift`, `ContentView`, `TerminalController+BrowserAutomation`, or `CLI+Hooks`. Move each lifecycle behind an owner with a narrow state model: app/window lifecycle, notification routing, CLI dispatch, browser RPC, hook installation. The goal is deleted cross-feature branching, not a same-size set of extension files.

### J5 — Validate recovery artifacts before object construction

Introduce a streaming/size-limited snapshot load and a structural validator that caps bytes, windows, workspaces, panels, tree depth, total nodes, and string sizes before any Workspace/TerminalSurface is created. The existing write-time prefixes are useful but cannot defend startup against corrupt, old, or edited files.

## Oversized-file inventory

Forty-eight non-test production files cross the 1,000-line bar. No repository document gives them explicit structural waivers. `Resources/mermaid.min.js`, third-party build products, generated Xcode files, and test files are excluded.

Immediate split candidates:

- `Sources/AppDelegate.swift` — 11,076
- `CLI/programa.swift` — 7,895
- `Sources/TerminalController+BrowserAutomation.swift` — 6,297
- `Sources/ContentView.swift` — 5,949
- `CLI/CLI+Hooks.swift` — 4,381
- `Sources/TabManager.swift` — 3,394
- `Sources/TerminalController.swift` — 3,149
- `Sources/Panels/BrowserDataImport.swift` — 3,054
- `Sources/Panels/BrowserPanel.swift` — 2,803
- `Sources/TerminalSurface.swift` — 2,788
- `Sources/SettingsView.swift` — 2,535
- `Sources/GhosttyApp.swift` — 2,457
- `Sources/Workspace.swift` — 2,349

Still oversized and requiring an explicit cohesion decision before the next feature lands:

- `Sources/GhosttySurfaceScrollView.swift` 2,796; `Sources/Panels/WebViewRepresentable.swift` 2,251; `CLI/CLI+TmuxCompat.swift` 2,138; `Sources/TabItemView.swift` 2,137; `Sources/ProgramaApp.swift` 2,075; `Sources/BrowserWindowPortal.swift` 2,061; `Sources/Panels/ProgramaWebView.swift` 2,010; `Sources/SessionEscrow.swift` 2,000.
- `Sources/TerminalController+Debug.swift` 1,925; `Sources/ProgramaSettingsFileStore.swift` 1,890; `Sources/SidebarVisuals.swift` 1,878; `Sources/AppDelegate+UITestHarnesses.swift` 1,822; `Sources/Panels/BrowserPanelView.swift` 1,734; `Sources/DebugWindows.swift` 1,694; `Sources/Update/UpdateTitlebarAccessory.swift` 1,639.
- `Sources/SessionWALStore.swift` 1,479; `CLI/CLI+SSH.swift` 1,403; `CLI/CLI+Browser.swift` 1,400; `Sources/TabManager+UITestHarness.swift` 1,366; `Sources/GhosttyTerminalView+Keyboard.swift` 1,233; `Sources/TerminalController+Telemetry.swift` 1,221; `Sources/TerminalController+Workspace.swift` 1,202; `Sources/TerminalController+Surface.swift` 1,165.
- `.github/workflows/ci.yml` 1,154; `Sources/SessionPersistence.swift` 1,126; `Sources/Workspace+Bonsplit.swift` 1,119; `.github/workflows/release.yml` 1,029; `Sources/BrowserWindowHostView.swift` 1,067; `Sources/Panels/Omnibar.swift` 1,061; `Sources/WindowPaneChromePortal.swift` 1,050; `Sources/TerminalWindowPortal.swift` 1,048; `Sources/CommandPaletteSearchEngine.swift` 1,015; `Sources/ClaudeQuotaMonitor.swift` 1,006.
- `Resources/shell-integration/programa-zsh-integration.zsh` 1,261 and `programa-bash-integration.bash` 1,115 are dialect-specific and cohesive, but their duplicated behavior still needs a shared conformance suite rather than a silent waiver.

## Detailed findings

### Structural regressions and correctness

### H1 — Entry points have become subsystem containers

**Location:** `Sources/AppDelegate.swift:1`, `CLI/programa.swift:1`, `Sources/TerminalController+BrowserAutomation.swift:1`, `Sources/ContentView.swift:1`, `CLI/CLI+Hooks.swift:1`. **Status:** CONFIRMED.

**Scenario.** A change to notifications, window election, browser focus, terminal routing, or session recovery enters the same 11,076-line `AppDelegate`; CLI protocol, user commands, race orchestration, and transport enter one 7,895-line executable. Reviewers cannot establish a feature's blast radius without reading unrelated state machines, and recent work added another 1,583 lines to `AppDelegate` and 3,896 to browser automation after the 2026-08-27 audit.

**Direction.** Apply J4. Enforce an owner and file-size budget for new behavior; do not “fix” this by moving identical extensions into arbitrary files.

### H2 — Socket clients implement mutually incompatible contracts

**Location:** `daemon/remote/cmd/programad-remote/cli.go:50`, `Sources/TerminalController.swift:1856`, `CLI/programa.swift:542`, `Sources/WorkspaceRemoteCLIRelayServer.swift:28`, `CLI-MCP/MCPSocketBridge.swift:90`. **Status:** CONFIRMED.

**Scenario A.** Remote `programa ping`, `new-window`, `current-window`, `close-window`, `focus-window`, and `list-windows` select `protoV1` (`cli.go:52-57`). `TerminalController` rejects every non-JSON line as `v1_removed` (`TerminalController.swift:1856-1864`), but `execV1` prints that error and returns 0 (`cli.go:203-212`). Automation sees success for a command that never ran.

**Scenario B.** The Swift CLI requires `cmux-relay-auth` (`CLI/programa.swift:542-552`); the relay server and Go client use `programa-relay-auth` (`WorkspaceRemoteCLIRelayServer.swift:28`, `cli.go:598`). The Swift remote endpoint cannot authenticate.

**Scenario C.** `MCPSocketBridge.send` connects and immediately sends the requested method (`CLI-MCP/MCPSocketBridge.swift:90-99`). Password mode requires `auth.login` first (`TerminalController.swift:1433-1492`), making the official MCP surface unusable in that mode.

**Direction.** Apply J1. Until then, migrate all six commands to v2, make v1 errors nonzero, align the relay identifier, and add an MCP credential/authentication path.

### H3 — Remote Claude startup trusts a cross-user temporary directory

**Location:** `daemon/remote/cmd/programad-remote/agent_launch.go:365-402`, `daemon/remote/cmd/programad-remote/agent_launch.go:530-539`. **Status:** CONFIRMED.

**Scenario.** On a multi-user remote host, another user precreates `/tmp/programa-claude-node-options` as a writable directory and replaces `restore-node-options.cjs` between Programa's atomic rename and Node startup. `ensureClaudeNodeOptionsRestoreModule` neither verifies directory ownership/mode nor rejects symlinks (`agent_launch.go:393-402`); `configureClaudeNodeOptions` adds the path to `NODE_OPTIONS` (`:530-539`). The victim's Claude Node process executes the attacker's JavaScript.

**Direction.** Put the module in a user-owned `0700` directory under `~/.programa`, verify ownership and non-symlink components, create files with restrictive modes, and open/execute by a verified path.

### H4 — Remote daemon downloads escape URLSession's file-lifetime contract

**Location:** `Sources/WorkspaceRemoteSessionController+DaemonInstall.swift:262-351`. **Status:** CONFIRMED.

**Scenario.** `downloadTask` stores its callback's temporary `localURL`, signals, and returns (`DaemonInstall.swift:300-317`). URLSession may remove that file when the completion handler returns; checksum and move happen afterward (`:318-351`). A normal successful download can therefore fail as “file not found.” Both manifest and artifact waits also discard the semaphore timeout result, so a timed-out callback can mutate captured state after the caller proceeds.

**Direction.** Move the file to an owned temporary URL inside the completion handler, return an immutable result through one synchronization primitive, cancel on timeout, and never read callback-owned mutable variables after an unchecked wait.

### H5 — Port settings accept values that trap Swift arithmetic

**Location:** `Sources/ProgramaSettingsFileStore.swift:671-680`, `Sources/SettingsView.swift:1282-1298`, `Sources/TerminalSurface.swift:196-202`, `Sources/TerminalSurface.swift:1300-1305`. **Status:** CONFIRMED.

**Scenario.** Settings JSON accepts any positive `Int` for `portBase` and `portRange` (`ProgramaSettingsFileStore.swift:671-680`); the UI adds no range constraint (`SettingsView.swift:1282-1293`). On terminal creation, `base + ordinal * range` and `start + range - 1` use trapping arithmetic (`TerminalSurface.swift:1300-1305`). `Int.max` plus a range of 10 crashes on the first terminal. Process-lifetime `static let` caching at `TerminalSurface.swift:196-202` also contradicts the UI note that new terminals inherit changed values.

**Direction.** Use one validated port-range value object constrained to 1...65535, use overflow-reporting arithmetic, reject ranges whose end exceeds 65535, and either load per new workspace or disclose restart-required behavior.

### H6 — Managed settings cross executors into an unsynchronized trust store

**Location:** `Sources/ProgramaSettingsFileStore.swift:118-134`, `Sources/ProgramaSettingsFileStore.swift:234-248`, `Sources/ProgramaDirectoryTrust.swift:82-149`, `Sources/ProgramaDirectoryTrust.swift:223-227`. **Status:** CONFIRMED.

**Scenario.** UserDefaults and notification observers call `reapplyManagedSettingsIfNeeded` on whichever queue posts (`ProgramaSettingsFileStore.swift:118-134`). The store lock protects snapshot selection but is released before apply (`:234-248`). Applying trusted-directory settings calls methods that read/write `ProgramaDirectoryTrust.trustedDirectories` and save/post without any lock or actor (`ProgramaDirectoryTrust.swift:82-149,223-227`). Concurrent settings, password, and trust notifications can race dictionary mutation and persistence.

**Direction.** Give managed settings one executor and make applying a resolved snapshot atomic. Isolate the trust store behind the same actor/serial queue; publish notifications only after committed state is visible.

### H7 — Recovery input is bounded after, not before, dangerous work

**Location:** `Sources/SessionPersistence.swift:388-449`, `Sources/TabManager+SessionPersistence.swift:81-94`, `Sources/Workspace+Persistence.swift:96-138`, `Sources/Workspace+Persistence.swift:416-464`. **Status:** CONFIRMED.

**Scenario.** Startup uses unbounded `Data(contentsOf:)` and full `JSONDecoder` construction for the primary and history snapshots (`SessionPersistence.swift:388-449`). Workspace/window/panel prefixes only apply after decoding (`TabManager+SessionPersistence.swift:81-94`, `Workspace+Persistence.swift:48-50`). The indirect split layout is recursively decoded and rebuilt without depth/node validation (`SessionPersistence.swift:315`, `Workspace+Persistence.swift:416-465`). A corrupt or hand-edited snapshot can consume memory or stack and repeatedly prevent launch before the existing caps help.

**Direction.** Apply J5. Quarantine invalid snapshots after a bounded failure so the next launch can recover.

### H8 — iOS request timeouts wait for the request they are supposed to cancel

**Location:** `ios/ProgramaSpike/ProgramaSpike/BridgeConnection.swift:217-228`, `ios/ProgramaSpike/ProgramaSpike/BridgeConnection.swift:281-298`, `ios/ProgramaSpike/ProgramaSpike/BridgeConnection.swift:481-505`, `ios/ProgramaSpike/ProgramaSpike/BridgeConnection.swift:526-542`. **Status:** CONFIRMED.

**Scenario.** `withRequestTimeout` races the operation against sleep in a structured task group (`BridgeConnection.swift:281-298`). The operation parks in `withCheckedThrowingContinuation`, stored in `pending` (`:526-542`). Cancelling that child neither removes nor resumes it, and leaving the group waits for all children. Teardown would resume pending requests (`:481-505`) but connect calls teardown only after the timeout helper returns (`:217-228`). An authenticated peer that keeps QUIC open and never answers `system.ping` leaves the app on Connecting indefinitely.

**Direction.** Make timeout/cancellation own the request ID and atomically remove/resume the continuation. Test a silent peer and assert bounded return plus an empty pending registry.

### H9 — Mutable actions run with credentials

**Location:** `.github/workflows/claude.yml:21-38`, `.github/workflows/ci.yml:412`, `.github/workflows/ci-macos-compat.yml:310`. **Status:** CONFIRMED.

**Scenario.** `anthropics/claude-code-action@v1` receives `CLAUDE_CODE_OAUTH_TOKEN` in a job with `id-token: write`; checkout is also tag-pinned (`claude.yml:21-38`). `upload-artifact@v4` remains tag-pinned in `ci.yml:412` and `ci-macos-compat.yml:310`. A retargeted tag or compromised upstream release executes arbitrary code with the job's token surface.

**Direction.** Pin every external action to a reviewed 40-character commit SHA, annotate the human version, and add a workflow lint that rejects mutable external `uses:` values.

### H10 — Remote daemon toolchain is outside Go's support window

**Location:** `daemon/remote/go.mod:3`. **Status:** CONFIRMED.

**Scenario.** `daemon/remote/go.mod` declares Go 1.22. As of this audit, Go 1.27 is current and only the two most recent major releases are supported. The daemon imports `net`, crypto primitives, and handles attacker-controlled remote/session inputs, so continuing to build against an unsupported standard-library line misses accumulated security fixes.

**Direction.** Upgrade at least to the latest 1.26 patch (or 1.27 after migration), pin the CI toolchain, rebuild release assets, and exercise remote compatibility. Sources: [Go release policy and history](https://go.dev/doc/devel/release).

### Boundary, lifecycle, and dependency findings

### M1 — iOS newline framing is unbounded and quadratic

**Location:** `ios/ProgramaSpike/ProgramaSpike/BridgeConnection.swift:388-406`, `Sources/MobileBridge/MobileBridgeStreamSupport.swift:17-65`. **Status:** CONFIRMED.

An authenticated endpoint can send bytes forever without `\n`; `nextBufferedLine` appends 64 KiB chunks and calls `firstIndex` from the start each time (`BridgeConnection.swift:388-406`). Memory is unbounded and scan work is O(n²). Port `MobileBridgeStreamLineReader`'s 8 MiB cap and incremental cursor (`Sources/MobileBridge/MobileBridgeStreamSupport.swift:17-65`).

### M2 — The shipped mobile identity remains spike-grade

**Location:** `ios/ProgramaSpike/ProgramaSpike/SecretKeyStore.swift:3-16`, `ios/ProgramaSpike/ProgramaSpike/PairingStore.swift:3-17`. **Status:** CONFIRMED.

`SecretKeyStore` persists the Iroh private key in UserDefaults and labels the design “spike-grade” (`SecretKeyStore.swift:3-16`); `PairingStore` does the same for the ticket (`PairingStore.swift:3-17`). A container or backup disclosure provides both the stable allowlisted identity and reconnection address. Migrate the key and ticket to Keychain with an explicit device-only accessibility class and atomic migration.

### M3 — Browser extensions silently receive permanent broad authority

**Location:** `Sources/Panels/BrowserExtensionManager.swift:111-172`, `Sources/Panels/BrowserPanel.swift:974-978`. **Status:** CONFIRMED.

Opening the first browser loads every unpacked directory/zip from `~/.config/programa/extensions` and grants every permission/match pattern until `distantFuture` (`BrowserExtensionManager.swift:111-172`). A copied extension with `<all_urls>` silently reads every Programa browser page. Require an enable/consent UI, show requested hosts, support revocation, and default new/changed permissions to denied.

### M4 — Bounded-input policy is repeatedly applied after allocation

**Location:** `Sources/Panels/ProgramaWebView.swift:1158-1443`, `Sources/Panels/BrowserHistoryStore.swift:73-180`, `Sources/VSCodeIntegration.swift:289-307`, `Sources/ReviewDiffProber.swift:139-290`. **Status:** CONFIRMED.

- Context-menu downloads use `Data(contentsOf:)` and URLSession `dataTask` for whole file/network bodies (`ProgramaWebView.swift:1158-1171,1229-1262,1389-1443`).
- Browser history synchronously loads and decodes the whole file, then enforces 5,000 entries only on later mutations (`BrowserHistoryStore.swift:73-75,146-180,233-237`).
- VS Code startup appends output until it finds a URL, with no byte cap (`VSCodeIntegration.swift:289-307,473-505`).
- Review diffs parse full Git output before marking per-file hunks over 400 KiB non-diffable (`ReviewDiffProber.swift:139-184,225-290`).

Use streaming/file-size gates and enforce limits while reading. One shared bounded collector should make an absent limit impossible.

### M5 — Escrow holder election has a probe/unlink/bind TOCTOU

**Location:** `Sources/SessionEscrow.swift:491-509`, `Sources/SessionEscrow.swift:1288-1303`, `Sources/SessionEscrow.swift:1351-1357`. **Status:** PLAUSIBLE.

Two holders can both fail the connect probe (`SessionEscrow.swift:1351-1357`). Holder A binds; holder B then calls `bindListening`, which unconditionally unlinks the path before bind (`:491-509`), making A unreachable and allowing B to take over. This is interleaving-dependent but the operations are visibly non-atomic. Bind without unlink first, classify `EADDRINUSE`, and only remove a verified stale socket under a lock/election primitive.

### M6 — Subprocess policy is copied three times

**Location:** `Sources/GitMetadataProber.swift:495-565`, `Sources/ReviewDiffProber.swift:235-299`, `Sources/GitWorktreeManager.swift:267-334`. **Status:** CONFIRMED.

`GitMetadataProber`, `ReviewDiffProber`, and `GitWorktreeManager` each own a `Process` + two pipes + semaphore + terminate/SIGKILL sequence (`GitMetadataProber.swift:495-565`, `ReviewDiffProber.swift:235-299`, `GitWorktreeManager.swift:267-334`). Their comments explicitly cite copying. Extract one result type and runner; callers should supply command, timeout, and output ceilings only.

### M7 — CloudKit's local cache can permanently suppress repair

**Location:** `ios/ProgramaSpike/ProgramaSpike/CloudKitPush.swift:19-81`. **Status:** CONFIRMED.

After one successful subscription save, `cloudKitSubscriptionSaved` skips every future check (`CloudKitPush.swift:19-45,65-81`). Switching Apple accounts or deleting the server subscription leaves the local boolean true and push silently stops. Reconcile the fixed subscription ID in the current private database and invalidate on `CKAccountChanged`.

### M8 — iOS reports a transient relay path as final

**Location:** `ios/ProgramaSpike/ProgramaSpike/PathClassifier.swift:42-55`, `tools/mobile-spike/Sources/iroh-spike/PathClassifier.swift:44-74`. **Status:** CONFIRMED.

Production returns the first non-unavailable path (`PathClassifier.swift:42-55`), while the spike documents Iroh's relay-first behavior and waits for direct/private settlement. Port that settled-path algorithm and its deterministic snapshot-sequence tests.

### M9 — Zig has nine version sources but setup validates none

**Location:** `scripts/setup.sh:12-19`, `scripts/ensure-ghosttykit.sh:44-48`, `ghostty/build.zig.zon:6`. **Status:** CONFIRMED.

Setup and `ensure-ghosttykit` check presence only (`scripts/setup.sh:12-19`, `scripts/ensure-ghosttykit.sh:44-48`), while Ghostty requires 0.16.0 (`ghostty/build.zig.zon:6`) and nine workflow locations hardcode that value. The currently provisioned 0.15.2 passes setup and fails inside the expensive build. Keep one authoritative version file/helper and consume it in setup and workflows.

### M10 — TestFlight signing mutates persistent developer state

**Location:** `scripts/build-ios-testflight.sh:55-112`. **Status:** CONFIRMED.

`build-ios-testflight.sh` deletes/creates the fixed `ios-build.keychain`, replaces the entire user search list with it, and installs profiles (`:55-112`). There is no EXIT trap. A local run leaves normal keychains undiscoverable, including after the CI-style cleanup deletes the only listed keychain. Use a unique temporary keychain, capture/append/restore the prior list, and remove exact installed artifacts in a trap.

### M11 — Mobile transport is both linked-unused and reimplemented

**Location:** `ios/ProgramaSpike/project.yml:5-21`, `tools/mobile-spike/Package.swift:10-35`, `plans/golden-tumbling-gray.md:187-193`. **Status:** CONFIRMED.

The iOS project and mobile spike link `CmuxIrohTransport`, but their sources import only `IrohLib`; the golden plan explicitly calls Cmux reference-only. The hand-copied implementations have already drifted on path settlement and line bounds. Remove Cmux from compiled dependencies, port the remaining correct spike behavior, then remove the completed executable spike while retaining concise provenance docs.

### M12 — Two direct dependencies miss material released fixes

**Location:** `GhosttyTabs.xcodeproj/project.pbxproj:2236-2262`. **Status:** CONFIRMED.

- Sparkle resolves 2.9.4; 2.9.5 and 2.9.6 add symlink-destination, installer-archive movement, and signature-validation hardening. Upgrade to 2.9.6 after updater tests. Source: [Sparkle 2.x changelog](https://github.com/sparkle-project/Sparkle/blob/2.x/CHANGELOG).
- Iroh is pinned to `1.0.2-cmux.3`; the fork's latest stable is `.8`, adding relay-token continuity, cancellation ownership, idle-path false-demotion fixes, and corrected artifacts. Upgrade deliberately with mobile/remote connection tests.

Swift Markdown UI 2.4.1, MCP Swift SDK 0.12.1, and swift-toml 2.0.0 are current. Ghostty's pinned SHA matches the Darkroom fork's `main`. Bonsplit is intentionally vendored in-tree. No role-overlap concern survived for those dependencies.

### M13 — App discovery has conflicting implementations

**Location:** `scripts/reload.sh:324-345`, `scripts/reloads.sh:156-177`, `scripts/reloadp.sh:10-16`, `scripts/run-tests-v2-ci.sh:43`. **Status:** CONFIRMED.

`reload.sh` and `reloads.sh` select mtime-sorted builds, `reloadp.sh` uses another search, and CI/smoke scripts take an arbitrary first match. Persistent DerivedData can select a stale app. Use the known DerivedData path in build jobs and one deterministic locator elsewhere. This carries forward the 2026-08-19 N12 finding.

### M14 — `programa race` can block before it reads Git output

**Location:** `CLI/programa.swift:5877-5896`. **Status:** CONFIRMED.

`existingRaceIndexes` connects stdout/stderr pipes, calls `waitUntilExit`, then drains stdout (`CLI/programa.swift:5877-5896`). A repository with enough matching refs fills the pipe, blocks Git, and makes `waitUntilExit` permanent. Use the canonical concurrent-drain runner from J2.

### M15 — tmux wait signals collide across users and sessions

**Location:** `daemon/remote/cmd/programad-remote/tmux_waitfor.go:10-20`, `daemon/remote/cmd/programad-remote/tmux_commands.go:509-548`, `CLI/CLI+TmuxCompat.swift:1557-1560`, `CLI/CLI+TmuxCompat.swift:1667-1694`. **Status:** CONFIRMED.

Both implementations sanitize a caller name into `/tmp/programa-wait-for-<name>.sig` (`tmux_waitfor.go:10-20`, `CLI+TmuxCompat.swift:1557-1560`). No user/session namespace or ownership check exists; Go ignores write/remove errors (`tmux_commands.go:522-544`) and Swift treats a pre-existing file as success (`CLI+TmuxCompat.swift:1675-1691`). Another local user or concurrent Programa session can spoof or consume the signal. Put signals in a user-owned runtime directory and include session identity.

### M16 — Relay stderr callbacks outlive their process ownership

**Location:** `Sources/WorkspaceRemoteSessionController+ConnectionOrchestration.swift:262-321`. **Status:** PLAUSIBLE.

The readability handler reads on its callback queue and later enqueues a buffer append (`ConnectionOrchestration.swift:262-277`). Teardown clears the handler, pipe, and buffer on the controller queue (`:281-321`) but cannot cancel an append already captured. That append can land after teardown and become the next relay's diagnostic prefix. This needs a generation token or per-process collector before promotion from PLAUSIBLE.

### M17 — Notification callback isolation is implicit

**Location:** `Sources/AppDelegate.swift:10301-10340`. **Status:** PLAUSIBLE.

`userNotificationCenter(_:didReceive:)` directly calls model/AppKit routing and `NSApp.activate` (`AppDelegate.swift:10301-10340`). The delegate callback does not state or enforce a main-queue contract. If UserNotifications invokes it off-main, AppKit and main-owned workspace state are touched from the wrong executor. Add an explicit `Task { @MainActor in ... }`/dispatch boundary and call the completion handler according to the API contract. Status remains PLAUSIBLE because this audit did not instrument callback queues.

### M18 — iOS reconnect can collapse to one retry

**Location:** `ios/ProgramaSpike/ProgramaSpike/AppStore.swift:276-306`, `ios/ProgramaSpike/ProgramaSpike/AppStore.swift:420-427`. **Status:** PLAUSIBLE.

On failure, the phase consumer calls `scheduleReconnect`, which refuses while `reconnectTask` is nonnil (`AppStore.swift:276-306,420-427`). If the failed phase is consumed before the current task reaches its final `reconnectTask = nil`, no successor is scheduled; the UI remains “Reconnecting…” without a task. Replace recursive phase scheduling with one generation-owned backoff loop. A fake connection/clock test should confirm the interleaving.

### L1 — Pairing recovery text references deleted controls

**Location:** `ios/ProgramaSpike/ProgramaSpike/PairConnectView.swift:108-114`, `ios/ProgramaSpike/README.md:20-27`. **Status:** CONFIRMED.

The UI intentionally removed legacy ticket/token fields, but its invalid-paste error and both localizations instruct the user to paste the ticket/token “below”; the README also documents a nonexistent Advanced section. Update the localized error and README to the combined-code flow.

## Dependency inventory

| Direct dependency | Pinned/resolved | Current assessment | Disposition |
|---|---:|---|---|
| Sparkle | 2.9.6 | Upgraded and resolved | Keep |
| swift-markdown-ui | 2.4.1 | Current; modern Theme API use | Keep |
| iroh-ffi fork | 1.0.2-cmux.3 | `.8` is stable but its manifest checksum does not match its release asset; `.9-dev.1` is prerelease | Keep `.3` until corrected stable release |
| MCP swift-sdk | 0.12.1 | Current; bridge contract, not SDK, is broken | Keep; fix H2 |
| swift-toml | 2.0.0 | Current; TOMLDecoder use aligns with docs | Keep |
| Bonsplit | vendored | Deliberate in-tree fork | Keep |
| Ghostty | `bccfc833...` | Matches Darkroom fork main at audit time | Keep pinned |
| Go standard library | `go 1.26.7` | Supported patched toolchain line | Keep patched |
| create-dmg | 8.0.0 | Exact isolated build dependency; currency not independently verified | Keep pending release-tool review |

Context7 was queried for the five direct Swift packages. Official upstream release sources were used for temporal version claims. Dependency versions are time-sensitive; recheck immediately before upgrading.

## Design tensions

1. **Incident fixes accumulate in coordinators.** The code has excellent explanations for past races, but each fix adds another flag, generation, timer, or callback to a central object. Weigh lifecycle-specific actors/controllers against the current global-coordinator model.
2. **Recovery prioritizes feature richness over a small trusted core.** Snapshot history, WAL, escrow, reattach, orphan reconciliation, and fresh-spawn fallback interact during launch. Weigh a validated recovery transaction with explicit phases against continuing to add local race guards.
3. **Cross-language contracts are prose.** Swift, Go, MCP, shell integration, and iOS duplicate identifiers and semantics. Weigh schema/code generation or shared conformance fixtures against manual parity.
4. **“Spike” and “shipping” coexist.** The iOS target is named ProgramaSpike and documents shortcuts, yet TestFlight auto-ships it. Decide one quality bar and make the build graph reflect it.
5. **Bounds are caller discipline.** Several systems cap data only after reading/decoding. Weigh typed bounded primitives at trust boundaries against continued per-feature limits.

## Open questions

1. Are remote daemon hosts expected to be multi-user? H3 is exploitable in that deployment; even on single-user hosts the path remains an integrity footgun.
2. Is socket password mode intended to support MCP? If not, the MCP command should fail at startup with an explicit unsupported-mode diagnostic rather than every tool failing later.
3. Are browser extensions a user-facing feature or developer-only experiment? Current code loads them in production without an enable switch.
4. Is the iOS app considered production because it auto-ships to TestFlight, or should the workflow be disabled until M1/M2/H8 are resolved?
5. Should session snapshots be treated as user-editable recovery artifacts? The current docs and manual restore affordances imply yes, which makes H7's validator mandatory rather than defensive hardening.

## Prior-audit reconciliation

- 2026-08-27 managed-settings race, unbounded session restore, browser download/history bounds, VS Code output, and notification isolation remain and are carried forward above.
- Duplicate-instance termination, Google query routing, Sparkle relaunch, tab-drag equality, `notification.clear` synchronization, bounded socket handle maps/line buffers, mobile revoke, and browser restore transfer were verified as changed and are not re-reported.
- 2026-08-25 current-tip release shipping and rolling-asset ceiling findings are resolved by main-push CI and bounded rolling-candidate archives.
- 2026-08-19 app discovery is resolved by one locator plus job-specific DerivedData roots (M13). The earlier “delete unwired Cmux vendors” recommendation remains narrowed: provenance-only vendor references stay, while M11 removes compiled-unused dependencies and the divergent completed spike.

## Considered and rejected

- **Main control-socket blind unlink:** deliberately deferred in current design records; not re-litigated in this codebase audit.
- **The `TerminalController` browser-download `SHORTCUT:`:** its documented concurrency trigger was not proven to have fired, so the marker remains valid debt rather than a finding.
- **Portal duplication:** the former browser/terminal transfer duplication now has `WebKitSubviewTransfer`; the prior structural complaint is resolved.
- **Release provenance and cache publication:** current-tip guards, checksum checks, archive traversal defense, lock ownership, and atomic publish paths survived review.
- **Go daemon package count:** a small stdlib-only daemon is not inherently under-factored; only concrete protocol/security/lifecycle issues are reported.
- **MCP additional JSON properties:** no executable validation bypass survived tracing.
- **`proxy.open` breadth:** current exposure matches the explicit remote-proxy design; no accidental public listener was found.
- **XcodeGen installed by unpinned Homebrew:** reproducibility tension, but no current breakage was proven; not promoted to a finding.
- **Sequential iOS workspace resync:** potentially slow, but no measurement exists; performance speculation is excluded from this codebase audit.
- **Large shell integrations:** their dialect-specific size is cohesive enough to avoid a split demand, but not enough to waive cross-shell conformance testing.

## Verification handoff

Every locally actionable finding now has executable runtime or artifact coverage in the landing series. The tagged Debug build passes. Repository policy assigns the suites to GitHub Actions, so the remaining handoff is the required red test-only commit followed by the green implementation commit, CI, and the automatically triggered rolling release. M12's Iroh half must be retried when upstream publishes a corrected stable artifact.
