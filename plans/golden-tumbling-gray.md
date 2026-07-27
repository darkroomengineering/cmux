# Programa Mobile — watch & unblock agents from your phone

## Context

Programa runs coding agents (Claude Code, Codex, OpenCode) in terminal panes across
workspaces. Walk away from the Mac and you lose all visibility: an agent that hits an
approval prompt sits blocked indefinitely, and you find out when you come back.

This plan adds a mobile companion that closes that loop — see which agents are working vs
stuck, get notified when one needs you, answer it from the phone.

**Decisions locked with the user before planning:**

| Decision | Choice |
|---|---|
| Day-one job | **Watch + unblock agents.** Not full terminal emulation. |
| Transport | **P2P, no server we host.** Port the Iroh work from upstream. |
| Stack | **Native iOS, SwiftUI.** |
| Reachability | **Anywhere**, via iroh's default (n0-operated) relay fallback. |
| Notification surface | **Live Activity / widget.** See "Push" — this needs a decision at M3. |

### Why this is a port, not a greenfield build

Programa is a fork of `cmux`. Upstream **already shipped this exact app to the App Store** —
`ios/AppStoreReview/` on `upstream/main` carries v1.0.0 metadata and screenshots named
`01-workspaces.png` and `02-notifications.png`. 1,715 Swift files sit under
`Packages/{iOS,Shared}`.

But the divergence is severe — merge-base `179b16ce67`, with **394 commits ours / 4,706
theirs**. Upstream restructured into `Packages/` + `Native/`; Programa kept a flat `Sources/`.
So the question is not whether to build it, but how much can cross that gap.

### What the research established

**Programa's local control plane is already dashboard-ready.** The hard product modelling
is done:

- `AgentActivityState` (`Sources/AgentActivityState.swift:18-38`) is a first-class
  `working | blocked | idle`, driven by real agent lifecycle hooks (`CLI/CLI+Hooks.swift`).
- **`blocked` already means precisely "a human is needed"** — only an approval prompt
  ("Permission") or an idle/AskUserQuestion wait ("Waiting") sets it
  (`CLI/CLI+Hooks.swift:604-611,1227-1250,2617-2640`). Everything else maps to `idle`.
  This is the notification trigger, already correct. No new detection logic needed.
- `Workspace.aggregateAgentState` (`Sources/AgentActivityState.swift:59-64`) already does the
  worst-of rollup (blocked > working > idle) — exactly the shape of a workspace status pill.
- A live event stream exists: `subscribe` in `Sources/TerminalController+Subscriptions.swift`
  (spec `docs/v2-api-migration.md:373-450`) with `agent_state` / `output` /
  `workspace_lifecycle` classes, coalesced output, and drop-oldest backpressure emitting
  `{"event":"dropped","count":N}`.
- The reply path is complete: `surface.send_text`, `surface.send_key`, and composite
  `agent.prompt` (send + wait-for-idle, `docs/v2-api-migration.md:257-315`).

**The entire gap is the network leg.** No TCP/WebSocket/HTTP listener exists anywhere in
`Sources/`. No APNs, no device tokens. Notifications are local `UNUserNotificationCenter`
only (`Sources/TerminalNotificationStore.swift`). Auth is five local access modes
(`Sources/SocketControlSettings.swift:7-61`) topping out at a single shared password.

**The upstream Iroh transport is liftable — but only half of it.** Its admission model has
two paths, and the split is the single most important fact for the "no server" decision:

- An **online path** (`CmxIrohOnlineAdmissionRegistry`, `pairGrant` credentials,
  `CmxIrohBrokerCredentialRepository`, `CmxIrohAccountRelayConfiguration`) requiring cmux's
  own hosted trust broker plus a `StackAuth`-backed account system. **Delete this.**
- An **offline path** (`CmxIrohOfflinePairingSessions` — "one-use Mac invitation state for
  offline same-account pairing", `CmxIrohBonjour` LAN discovery, asymmetric
  `CmxIrohGrantVerifier`) that needs no account, no broker, no backend. **Keep this.**

Verified decoupling that makes the lift feasible: no file in `CmuxIrohTransport` imports
`CMUXAuthCore` / `CmuxAPIClient` / `CmuxSyncStore`; `CMUXMobileCore` has zero external
package deps; the only external dependency is public `manaflow-ai/iroh-ffi` pinned at
`1.0.2-cmux.3` — same org Programa already vendors `bonsplit` from. Both packages declare
`platforms: [.iOS(.v18), .macOS(.v14)]`, so one package serves phone and Mac host.

### What the reference products confirm

| | Happy | **Orca** | Warp/Oz |
|---|---|---|---|
| Transport | cloud relay, E2E, QR pair | **direct pairing code, no relay** | cloud only |
| Notify on | permission needed / error | agent finished | desktop only |
| Terminal on phone | abstracted to chat feed | read-only scrollback + opt-in Live mode | none |

**Orca is the closest analog** — a Ghostty-inspired desktop terminal running many CLI agents
across git worktrees, with a phone satellite paired by one-time code and no cloud between.
That is the architecture chosen here, which is good evidence the P2P path works as a product
and not just as engineering.

All three converge on: **do not put a live PTY on a phone.** Show status, abstract the
terminal to a readable feed, reply in natural language, notify when blocked.

Programa's `blocked` signal matches Happy's trigger, which is the better of the two for this
job — Orca's "agent finished" tells you too late to unblock anything.

---

## Product shape (v1)

Three screens. Anything beyond this is out of scope for v1.

1. **Workspace list** — every workspace with a worst-of state badge from
   `aggregateAgentState`. Blocked sorts to the top. This is the glance screen.
2. **Agent detail** — recent output as a readable feed (not a PTY), current state, and a
   text box that sends via `agent.prompt`.
3. **Pairing** — one-time code / QR, and a paired-devices list on the Mac with instant revoke.

Explicitly deferred: live terminal mode, file browser, source control / diff review, browser
session view, workspace creation.

---

## Layer strategy

Three layers, three different tactics, because coupling differs sharply.

| Layer | Upstream source | Files | Coupling | Tactic |
|---|---|---|---|---|
| Transport spine | `Packages/Shared/{CMUXMobileCore,CmuxIrohTransport}` | 119 + 332 | low (after stripping) | **Vendor & strip** |
| Mac host bridge | `Sources/Mobile/*`, `Packages/macOS/CmuxControlSocket/.../MobileHost/` | small | **very high** | **Write fresh** |
| iOS UI | `Packages/iOS/*` | ~400 | high | **Write fresh** |

**Cherry-pick is not viable** across 4,706 commits of divergent restructuring. Code crosses
as a **one-time vendored source copy**, materialized with `git show upstream/main:<path>`
into `vendor/CmuxIrohTransport/` and `vendor/CMUXMobileCore/`, following the `vendor/bonsplit`
precedent (local SPM package by path, not a submodule). Each gets a `PROVENANCE.md` recording
the exact upstream SHA, since there is no live tracking afterward.

Not a live SPM dependency on the fork: `CmuxIrohTransport` is nested inside cmux's monorepo,
not a standalone repo, and every future upstream commit risks silently reintroducing
broker/`StackAuth` coupling we are deliberately deleting.

### Revised after M0 spike: inject an offline broker, don't delete files

The original plan assumed we'd delete ~12 broker files and untangle the 29 that reference
them. **Reading the code showed that's wrong and unnecessary.**

`CmxIrohHostBrokerServing` is a *protocol* (`CmxIrohHostBrokerServing.swift`), and
`CmxIrohHostRuntime` takes `any CmxIrohHostBrokerServing` by injection
(`CmxIrohHostRuntime.swift:62,113,132`). `CmxIrohTrustBrokerClient` — the HTTP client that
talks to cmux's hosted backend — is just one conformance, attached by a one-line extension.
The 29 "coupled" files depend on **the seam, not the server**.

So:

- **Write** `ProgramaOfflineBroker: CmxIrohHostBrokerServing` — five methods total:
  `discover()`, `issueRelayToken(bindingID:endpointID:)`, `revoke(bindingID:)`,
  `register(prepared:signer:)`, `issueEndpointAttestation(bindingID:)`. Backed by
  `CmxIrohOfflinePairingSessions` (which already exposes `createInvitation` /
  `verifyAndConsume` / `setPairingEnabled` / `revoke`) plus local storage. No network.
- **Never construct** `CmxIrohTrustBrokerClient`. Enforce with a build-time check that the
  type is unreferenced from Programa code, so the HTTP path is provably dead rather than
  merely unused.
- **Delete nothing** in the initial vendoring. The vendored tree stays byte-identical to the
  recorded upstream SHA, which keeps `PROVENANCE.md` honest and re-extraction trivial. Prune
  genuinely dead files later, as a separate cleanup, once the offline path is proven.

This is both cheaper and safer than deletion: no risk of breaking the 421 passing tests by
severing something subtle, and the security property we wanted ("the broker path is not
reachable") is achieved by never injecting it.

Iroh's n0-operated relay fallback stays — third-party infrastructure that already exists,
not a server we run.

**Why the Mac bridge is written fresh, not lifted:** upstream's flat `Sources/Mobile/*` imports
`StackAuth` / `CmuxAuthRuntime` / `CmuxSettings` — cmux's account system, which Programa has
none of and doesn't want. And `Packages/macOS/CmuxControlSocket/.../MobileHost/*` dispatches
`mobile.terminal.create/input/replay/viewport/scroll/mouse` — a full terminal-mirroring data
plane, i.e. exactly the scope that was ruled out.

**Why the iOS UI is written fresh:** `CmuxMobileWorkspace` is account-gated
(`MobileRootAuthGate`, `MobileOnboardingGate`, `SignInCodeInputPolicy` all live inside it), and
`CmuxMobileShellUI` is 193 files of full terminal rendering. Both are the wrong shape for a
status-list-plus-prompt-box product. The App Store screenshots are worth reading as **UX
reference**; `CmuxMobilePairedMac` (14 files) is worth imitating for paired-Mac persistence —
neither is worth copying.

---

## Mac host bridge design

New flat directory `Sources/MobileBridge/`, matching Programa's convention
(`WorkspaceRemoteCLIRelayServer.swift` is the closest existing analog and is also a flat file):

- `MobileBridgeListener.swift` — owns the stripped transport runtime: binds an Iroh endpoint,
  advertises via `CmxIrohBonjour`, wires `CmxIrohAdmissionController` restricted to offline
  pairing.
- `MobileBridgeSession.swift` — one per admitted peer; owns the frame relay.
- `MobileBridgeSettings.swift` — pairing mode + device revocation list.

### It's a relay, not a translator

Phone and Mac already speak identical newline-delimited JSON-RPC. Upstream needed a
translation layer only because their Mac side moved to a typed
`ControlCallResult`/`ControlCommandCoordinator`; Programa's did not. So:

1. Read newline-delimited bytes off the admitted peer's control lane.
2. Dispatch each line **in-process** via `processV2Command` (currently `private` at
   `Sources/TerminalController.swift:1477` — bump to `internal`), rather than opening a second
   `AF_UNIX` connection per session.
3. Write the response line back over the same lane.
4. For subscribed connections, relay `SocketEventBroadcaster` push frames back over the lane.
   `MobileBridgeSession` should construct a real `SocketConnection` wrapping its Iroh lane, so
   subscription semantics come for free.

In-process dispatch is safe because Programa's socket handlers were already built for it:
CLAUDE.md's "Socket command threading policy" mandates handlers assume an arbitrary
non-main thread and hop to main via `v2MainSync` — exactly what an Iroh callback thread
provides.

This means **`agent.prompt` becomes the phone's entire answer/approve action with zero new
Mac-side logic** — the same call the CLI's `prompt-agent` already uses.

*Fallback if in-process dispatch proves unsafe:* a genuinely long-lived connection to
`programa.sock` per peer. Note `WorkspaceRemoteCLIRelayServer.Session` is intentionally
one-shot (connect → write → `SHUT_WR` → drain → close), which is the wrong shape for a session
that must keep receiving push frames.

### Keep pairing orthogonal to `SocketControlSettings` — do not add a sixth access mode

The five existing modes answer "who may open `programa.sock`" using a **process-trust**
primitive (ancestry, shared password, file permissions). An Iroh peer is never a local process
— it's a remote peer admitted by an **asymmetric pairing credential**, a categorically
different primitive. A paired phone has no meaningful "socket file permissions"; under
in-process dispatch it never touches the socket file at all.

So: a separate `MobileBridgeMode { off, pairedDevicesOnly }` with its own Settings section
("Phone pairing"), its own persistence, and its own instant local revoke. The phone's
authorization boundary sits entirely *upstream* of the socket, at Iroh admission time — it
never widens the existing gate.

### Security implications, stated plainly

- **Scope creep is the real risk.** In-process dispatch inherits the *entire* v2 method
  surface by default — including `worktree.remove`, `browser.navigate`, `debug.*`. **Enforce
  an explicit method allow-list inside `MobileBridgeSession` before dispatch**, scoped to
  `system.ping`, `workspace.list`, `surface.list`, `subscribe`, `unsubscribe`, `agent.prompt`,
  `surface.send_text`, `surface.send_key`. Anything else returns `forbidden`. This list must
  be revisited whenever a v2 method is added, or the phone silently gains unreviewed
  capabilities.
- **Revocation must be instant and local** — no broker round-trip (we deleted that path), so a
  lost phone is killed from the Mac immediately.
- **Never put prompt or output text in a notification payload.** Keep it generic ("Agent needs
  input in `<workspace>`") and have the phone pull real state over the authenticated Iroh
  session on foreground.
- This is **materially safer than `SocketControlSettings.password` mode**, which is one shared
  secret in a 0600 file. The offline-pairing credential is asymmetric — no shared-secret leak
  surface — *provided* the broker/`pairGrant` path is genuinely deleted rather than merely
  unused.

---

## Resumability

**Decision: full-resync on reconnect. Do not add sequence numbers or a replay buffer.**

`surface.list` already returns complete `agent_state`/`agent_state_source` per surface
(`Sources/TerminalController+Surface.swift:9-72`) — that *is* the entire payload the watch
screen needs, so there is no cheaper resync than fetching the source of truth. It matches the
already-documented recovery contract for `dropped` frames, and has no buffer-expiry edge cases.

Sequence numbers would require a genuinely new mechanism: a subscription-independent bounded
ring buffer keyed by durable subscriber identity, seq threaded through every event type, a
`since_seq` parameter, and replay-correctness handling — none of which any existing consumer
needs. Today's `EventSubscription` is created fresh per `subscribe` and has zero persistence
across a torn-down connection; a reconnecting phone is a *new* subscription, not a resuming one.

Phone-side discipline: treat every I/O error identically (dropped frame, closed socket, cold
launch) — full resync once, debounced against drop bursts, then re-`subscribe` for the live
tail.

Revisit only if field data shows `surface.list` latency becoming user-visible. For one
developer's Mac with dozens of surfaces, it won't.

---

## Push / Live Activity

**Honest constraint:** APNs requires a provider holding an auth key to talk to Apple, and iOS
suspends backgrounded apps. A Live Activity is a *presentation* choice — it still needs a push
path for remote updates. So the "no server we host" decision and the "notify me when blocked"
requirement are in genuine tension, and this plan does not paper over that.

**v1 (M2, free):** the Live Activity updates locally whenever the Iroh session is alive —
foreground, and during the windows iOS grants background execution. Real value, zero
infrastructure, no APNs entitlement.

**M3 decision — two paths, costed, to be chosen then rather than now:**

- **Mac as APNs provider.** The Mac holds the push key and POSTs to `api.push.apple.com`
  directly. Literally no server. Cost: the signing key ships inside the app, so anyone who
  extracts it can push to any device token they know. Acceptable for a personal/small-team
  tool, not for broad distribution.
- **Minimal stateless relay.** One function whose only job is signing and forwarding a push.
  Keeps the key server-side. Paired with a Notification Service Extension so the relay handles
  only ciphertext and never sees workspace names. Cost: one hosted piece, contradicting the
  literal "no server" constraint.

If the line on zero hosted infrastructure holds firm and Mac-as-provider is rejected, the
honest outcome is that notifications work only while the app is reachable, and the product
downgrades from "tells you when an agent is blocked" to "shows you when you open it." That is
a materially smaller product and worth a real conversation at M3 rather than a silent scope cut.

---

## Milestones

Riskiest assumption first. Sizes assume one engineer.

**M0 — Transport reachability spike. 1–2 weeks.**
No JSON-RPC, no UI. Vendor and immediately strip the two packages to the offline-pairing
branch; get `iroh-ffi@1.0.2-cmux.3` resolving and linking for both a macOS and a throwaway iOS
target; smallest possible Mac listener (bind, Bonjour advertise, accept one paired connection)
and iOS client (enter code, connect, echo bytes).
**Success:** a real Mac and a real iPhone hold a connection for several minutes, across both
LAN and cellular-to-home-WiFi.
*Touches:* `vendor/CmuxIrohTransport/**`, `vendor/CMUXMobileCore/**`, `GhosttyTabs.xcodeproj`,
disposable iOS test target.

**M1 — Mac host bridge, relay only, no UI. 1–2 weeks.**
`Sources/MobileBridge/{MobileBridgeListener,MobileBridgeSession,MobileBridgeSettings}.swift`;
bump `processV2Command` visibility; implement the method allow-list; add the pairing-mode
setting and device revoke. Validate from a scripted Iroh test client sending raw JSON-RPC —
confirm `subscribe` events flow and `agent.prompt` round-trips.
*Touches:* `Sources/MobileBridge/*` (new), `Sources/TerminalController.swift` (visibility
only), new Settings panel.

**M2 — iOS MVP: the actual watch-and-unblock. 2–3 weeks.**
Pairing flow, workspace list with state badges from `surface.list` + live `subscribe`, agent
detail with `agent.prompt` entry, Live Activity updating while connected.
*Touches:* new iOS app target, new small Swift package consuming only the vendored transport.

**M3 — Remote push. 1–2 weeks, gated on the decision above.**
Device-token registration, Mac-side trigger wired to the existing `blocked` transition (reuse
the classifier — no new detection), NSE with encrypted payload.

**M4 — Hardening. 1–2 weeks.**
Resync discipline, background-refresh tuning, multi-device pairing, App Store prep.

---

## Risks & kill criteria

Each has a concrete tripwire, discoverable at a named milestone.

### Retired by the M0 spike (2026-07-27)

- ~~**Offline pairing won't cleanly separate from the broker at compile time.**~~ **Retired.**
  Separation doesn't require surgery — broker access is a protocol seam, satisfied by
  injecting our own conformance. See the revised layer strategy above.
- ~~**`iroh-ffi@1.0.2-cmux.3` won't build/link on current Xcode.**~~ **Retired.** It resolves
  to a prebuilt, checksummed binary xcframework from a GitHub release (no Rust toolchain
  needed), carrying `ios-arm64`, `ios-arm64_x86_64-simulator`, and `macos-arm64_x86_64`
  slices. The vendored package builds clean in 19s on Xcode 26.3 / Swift 6.2.4, and its own
  suite passes **421 tests across 50 suites** — including
  `relayDisabledEndpointsCarryAuthenticatedBidirectionalRoundTrip`, a live QUIC round-trip
  with relay disabled.
- ~~**Admission crypto lives inside the Rust layer in a cmux-specific way.**~~ **Retired.**
  Admission is Swift-side and seam-injected; the Rust layer is generic iroh.

- ~~**Real-device reachability across networks.**~~ **Retired — M0 passed on hardware.**
  A real iPhone 16 Pro connected to the Mac and echoed the probe byte-exact on both networks:
  `private network` on shared Wi-Fi, and **`direct` on cellular with Wi-Fi off** — hole-punched
  through carrier NAT to a home router, no relay, no server. Confirmed from both ends
  independently. **The "P2P, no server we host" transport choice is validated as specified.**

### Still open

- **Xcode version skew.** We're on 26.3; upstream pinned 26.0 (`.xcode-version`). Everything
  builds today, but the vendored code was never CI-tested against 26.3. *Tripwire:* CI.
- **Direct-path reliability, not just possibility.** M0 proves hole-punching *can* work on this
  carrier and router. It says nothing about how often it fails on other networks (symmetric
  NAT, corporate Wi-Fi, CGNAT). The app must treat `relay` as a normal outcome and stay
  correct on it — only latency should change. Worth instrumenting the direct-vs-relay ratio
  once real devices are in use.

### Traps M0 surfaced — read before M1

Three separate settings each produced a green-looking result that proved the *opposite* of
what we wanted. All three are inherited from cmux and are wrong for a broker-less deployment:

1. **`presetMinimal()`** — iroh documents it as "no external dependencies; good for tests /
   offline". cmux uses it because their hosted broker supplies discovery. With it, a connection
   *never* leaves the relay: two processes on the same machine stayed relayed at 385 ms.
   `presetN0()` (relays **and** discovery) took the identical exchange to 1.1 ms peer-to-peer.
2. **Missing `NSLocalNetworkUsageDescription`** — iOS silently denies all LAN access without
   it, so the phone could not reach the Mac's `192.168.1.33` and fell back to relay *on the
   same Wi-Fi*. A missing Info.plist key is indistinguishable from "NAT traversal failed"
   unless you know to look.
3. **Path classifier returning the first path** — iroh always relays first and upgrades after
   hole-punching, so reporting the first selected path reads `relay` essentially always. The
   classifier must wait for the settled path or the measurement is meaningless.

The common thread: **a relayed connection looks identical to a working one unless you measure
the path.** Any M1 diagnostics must surface direct-vs-relay prominently, not bury it.
- **Relay fallback doesn't reliably bridge cellular-to-home-WiFi.** *Tripwire:* M0 field test.
  → Go/no-go moment for the whole transport choice, not a bug to fix later. Surface before
  committing to M1, because the tempting fix (self-host a relay) walks back the core decision.
- **In-process dispatch unsafe from an Iroh callback thread** (hidden reentrancy not visible
  from the stated threading policy). *Tripwire:* M1. → Doesn't kill the project; fall back to
  the long-lived socket connection. More code, still viable.
- **Admission crypto turns out to live inside the Rust layer in a cmux-protocol-specific way.**
  *Tripwire:* M0 echo server. → Write fresh against bare `iroh-ffi` with a simpler
  personal-pairing scheme.

---

## Verification

Per CLAUDE.md, **tests are never run locally** — E2E/UI via `gh workflow run test-e2e.yml`,
unit tests preferred through CI.

- **Builds:** `./scripts/reload.sh --tag mobile-bridge` for every Mac-side change. Never bare
  `xcodebuild`, never an untagged `Programa DEV.app`.
- **New Swift files must be added to `project.pbxproj`** (4 manual entries) or the build fails
  with "cannot find type in scope" — a known recurring miss.
- **M0:** manual two-device test. Log connection establishment, relay-vs-direct path, and
  sustained duration to the debug event log via `dlog()` (requires `import Bonsplit`, wrapped
  in `#if DEBUG`).
- **M1:** new `tests_v2/` python test driving the bridge over a loopback Iroh connection —
  assert allow-listed methods succeed, non-allow-listed return `forbidden`, and `subscribe`
  frames arrive. Follow the `tests_v2` authoring rules (marker-in-echo, own connection for
  concurrent sends, client timeout headroom). Never point tests at the production socket.
- **M2:** manual device testing against a tagged Debug build.
- **Regression tests for bugs** follow the two-commit policy — failing test first (CI red),
  then the fix (CI green).
- **All user-facing strings localized** via `String(localized:)` with keys in
  `Resources/Localizable.xcstrings` (English + Japanese).
- **New keyboard shortcuts**, if any, must land in `KeyboardShortcutSettings`, be editable in
  Settings, be supported in `~/.config/programa/settings.json`, and be documented.
