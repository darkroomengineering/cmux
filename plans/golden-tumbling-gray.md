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

### Tappable answers instead of a free-text box (scoped 2026-07-28, not built)

Requested after using the app: when an agent is blocked, the phone should show the agent's
actual question and its choices as buttons, rather than only offering a text field. Answering
"1" to a question you cannot see is the current experience.

**The two blocked cases are not equally ready, and that is the whole finding.**

*AskUserQuestion — the options already exist, structured.* `describeAskUserQuestion`
(`CLI/CLI+Hooks.swift:725-748`) already reads `tool_input.questions[].question` and
`options[].label` out of the `PreToolUse` payload. It then **flattens them into one display
string** (`"[Label A] [Label B]"`, line 742) and stores that as `lastBody` in the session
store. So the structure is captured and immediately thrown away. Making these tappable is
plumbing, not new capture: keep the array, carry it through the session store, expose it on
the v2 surface/agent-state payload, render buttons.

*Permission prompts — no structured options exist.* This is the far more common blocked case,
and `summarizeClaudeHookNotification` (`CLI/CLI+Hooks.swift:1225-1250`) only ever sees free
text: it scrapes `message`/`body`/`text`/`prompt` and truncates to 180 chars. Claude Code does
not hand the hook a choice list here. The realistic move is **not** to parse the prompt text
but to model the fixed, known set of permission answers as actions, and accept that the
button labels are ours rather than the agent's.

**Sending the answer back is the risky half.** The bridge allow-list already carries
`surface.send_key` and `surface.send_text`, so a tap becomes a key sequence into the TUI.
That is fire-and-forget into a live terminal: if the prompt has already been answered at the
desk, or the agent moved on, those keystrokes land somewhere arbitrary — potentially
selecting an unrelated menu item. Any implementation needs a staleness guard: carry an
identifier for the exact prompt the buttons were rendered from, and have the Mac reject the
tap if the surface's pending prompt is no longer that one. Without it this feature can
silently take destructive actions, which is strictly worse than the text box it replaces.

**Order of work:** AskUserQuestion first (structure already exists, low risk), the staleness
guard second, permission prompts last. Do not ship any of it before the guard.

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

### Revised again at M1: build on `IrohLib` directly, keep the package as reference

The kill criterion "admission is welded to cmux's world → write fresh against bare `iroh-ffi`"
**fired.** Investigation findings:

- **No cmux key material is hardcoded.** `CmxIrohGrantVerifier.publicKey(id:keySet:)`
  (`CmxIrohGrantVerifier.swift:247-278`) only checks structural shape — version, key count,
  valid Ed25519 SPKI DER. Keys are runtime values. So a self-signing broker is *possible*.
- **But the format contract is not injectable, only the keys are.** Conforming means
  reimplementing cmux's exact JWT-like claim sets, base64url/SPKI-DER encodings and lifetime
  windows, with no ability to simplify.
- **`CmxIrohHostRuntime.start()` has no broker-free path.** It unconditionally calls
  `register` (`+PolicyRefresh.swift:107`), `discover` (`:121`) and `issueEndpointAttestation`
  (`:145`) before `endpointServer.start()` accepts anything. The cached-policy fallback
  (`:161-195`) requires a *prior successful* round trip. Even offline-paired peers keep hitting
  `broker.discover()` every 30s via `CmxIrohOnlineAdmissionRegistry.authorizeOfflinePair`
  (`:117-134`, `:338`). There is no partial-conformance shortcut.
- **What the runtime adds is mostly inapplicable to us**: managed-relay credential rotation
  (dead unless `managedRelayURLs` is non-empty, `CmxIrohHostRuntime.swift:218-220`), LAN
  rendezvous rotation, fleet-scale revalidation. M0 already connects over LAN *and* cellular
  with none of it.

**Decision: the Mac listener is built directly on `IrohLib`**, exactly as the proven M0 spike
is (`tools/mobile-spike/Sources/iroh-spike/App.swift`). The vendored package stays in the tree
as **reference**, not as a compiled dependency — deleting it is easy later and reversible;
re-extracting it is not free. Worth rereading when needed: `CmxIrohStreamHeader*` (lane framing
for when one control channel isn't enough), `CmxIrohAdmittedConnectionSupervisor`
(control/application lane race-and-close), and `CmxIrohGrantVerifierTests.swift` as an
attack-case checklist if pairing ever grows into signed grants.

### v1 pairing: the EndpointID *is* the credential

iroh's EndpointID is an Ed25519 public key, and QUIC mutually authenticates it. So
authorization is **set membership**, with nothing forgeable:

1. Mac generates one long-lived `SecretKey` on first launch, stored in the Keychain. That is
   its identity — no separate broker key.
2. Pairing shows a QR/ticket: the Mac's EndpointID plus a random, memory-only, single-use
   token that expires in ~5 minutes.
3. Phone dials the EndpointID and presents the token on the first control message.
4. Mac verifies the window is open, the token matches (constant-time) and is unconsumed, then
   persists the phone's EndpointID to a trusted-device store and closes the pairing window.
5. Every later connection is authorized purely by "is this EndpointID in the store".
6. Revocation is removing the entry and dropping open connections — local and immediate.

An unpaired peer cannot enter the allowlist except through a deliberate, time-boxed ceremony,
and there is no signed artifact it could forge to talk its way in.

### Superseded: inject an offline broker, don't delete files

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

### It's a relay, not a translator — via a socketpair

Phone and Mac already speak identical newline-delimited JSON-RPC. Upstream needed a
translation layer only because their Mac side moved to a typed
`ControlCallResult`/`ControlCommandCoordinator`; Programa's did not.

**Revised after reading the code.** The original plan said `MobileBridgeSession` should
"construct a real `SocketConnection` wrapping its Iroh lane." That is not possible:
`SocketConnection` is a concrete `final class` holding a raw fd (`private let socket: Int32`,
`Sources/TerminalController+Subscriptions.swift:37-46`) and writing to it directly. It cannot
wrap anything that is not a file descriptor. Making it protocol-based would mean refactoring
the subscription machinery.

There is a much cheaper path. `handleClient(_ socket: Int32, peerPid: pid_t? = nil)`
(`Sources/TerminalController.swift:1390`) already takes an arbitrary fd and an *injectable*
peer PID. So per admitted phone:

1. `socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)` — two connected fds, no filesystem, no listener.
2. `Thread.detachNewThread { handleClient(fds[0], peerPid: getpid()) }` — the existing read
   loop, v2 dispatch, subscription lifecycle, event pushes and backpressure all run untouched.
3. Pump bytes both ways between `fds[1]` and the peer's Iroh bidirectional stream.
4. Enforce the method allow-list on lines read from the phone *before* they reach `fds[1]`.

**Nothing in `SocketConnection`, `processV2Command`, or the subscription code changes.** The
only edit to existing Programa code is bumping `handleClient` from `private` to `internal` —
one line. Subscription push frames flow back to the phone automatically because, as far as
Programa is concerned, this is just another socket client.

This also means **`agent.prompt` is the phone's entire answer/approve action with zero new
Mac-side logic** — the same call the CLI's `prompt-agent` already uses.

Note the socketpair deliberately does *not* rely on `cmuxOnly` ancestry checks for security
(`Sources/TerminalController.swift:1400-1425`). The phone's authorization boundary is the
Iroh admission handshake plus the bridge's own method allow-list, both entirely upstream of
this fd. The socketpair is a plumbing convenience, not a trust boundary.

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

**M3 — Remote push via CloudKit. 1–2 weeks.** Decided 2026-07-28 after research.

**Why CloudKit, and why not the obvious alternatives.** APNs tokens are bound to the app's
bundle ID and Team ID, so there is no per-user key: any provider pushing to our companion must
hold *our* `.p8`. Programa is publicly distributed, so shipping that key makes it extractable.
CloudKit escapes this entirely — each user's Mac writes to *their own* iCloud private database,
their own phone is subscribed, Apple delivers. No key distributed, no infrastructure we run,
per-user isolation by construction.

Research findings that settled it:

- **Happy Coder** claims "encrypted, we can't see the content" but
  `packages/happy-server/sources/app/push/pushSend.ts` POSTs **plaintext** title/body to Expo's
  public API. Expo holds the APNs key — including for self-hosters, since the push token is
  minted by Expo. Their E2E encryption covers message content, not notifications.
- **Home Assistant** — the closest analogue (thousands of self-hosted servers, one public iOS
  app) — routes through a **centrally-operated relay**. `homeassistant/components/mobile_app/
  notify.py` POSTs plaintext title/body to a `push_url`; HA core holds no APNs key. Free,
  500/day/target, not gated behind Nabu Casa. Notably `push_notification.py` tries a *local*
  channel first and only falls back to cloud push after ~10s — the same p2p-first shape we have.
- **Orca** does **no real push**: `mobile/src/notifications/` uses
  `scheduleNotificationAsync(trigger: nil)` — local only, while a live RPC connection exists.
  Their "no cloud relay" claim is true because a backgrounded phone is never woken.

**Nobody solves this without a relay or without giving up backgrounded wake.** CloudKit is the
only found path that gets both.

**Design:**

1. One `CKRecord` in the user's **private** database holding current blocked-agent summaries.
2. `CKQuerySubscription` created by the iOS app at pairing, with **both**
   `alertBody` (no `soundName`) **and** `shouldSendContentAvailable = true`. The alert promotes
   the push to the reliable high-priority channel and shows a lock-screen line without buzzing;
   the same delivery wakes the app to refresh its Live Activity locally.
3. **Alert text stays generic** ("An agent needs you"). Workspace names live only in the record,
   inside the user's own private DB — so the payload transiting Apple carries nothing
   meaningful. Stronger than Happy, which sends full plaintext to a third party.
4. **Foreground reconciliation is mandatory.** Silent pushes are coalesced to the latest,
   throttled ("two or three per hour"), and **discarded entirely after a force-quit**. The app
   must re-read the record and rebuild Live Activity state on every foreground.
5. **Gate on `CKContainer.accountStatus == .available`** and check both devices share an Apple
   ID during pairing. Mismatched accounts deliver nothing and raise **no error** — a silent
   failure mode.

**Live Activities are demoted, not deleted.** The notification is the contract; the Live
Activity is a bonus that refreshes when the silent push gets through. It is iOS-only and its
freshness rides the least reliable channel Apple offers, so it gets no further investment.

### Provisioning-profile groundwork done now, entitlement flip still gated

The release pipeline can embed a Developer ID provisioning profile
(`scripts/sign-release-app.sh` copies `$PROGRAMA_PROVISION_PROFILE` to
`Contents/embedded.provisionprofile` before the app is signed, wired through
`.github/workflows/release.yml` via an optional `APPLE_PROVISION_PROFILE_BASE64` secret,
verified with `scripts/verify-provision-profile.sh`). None of this enables CloudKit by
itself — `programa.entitlements` still carries no iCloud keys, and
`MobileBridgePush.releaseProvisioningComplete` stays `false` until the steps below are done.
**Steps 1 and 2 were completed on 2026-07-28.** What exists at Apple now:

- iCloud container `iCloud.com.darkroom.programa` — Active.
- App ID `Programa` / `com.darkroom.programa` — registered with the iCloud capability
  (CloudKit) and the container attached. It did **not** exist before: the Mac app is
  Developer-ID-signed with no provisioning, so nothing had ever needed one.
- Provisioning profile `Programa Developer ID CloudKit` — Developer ID Application, platform
  `OSX`, `ProvisionsAllDevices: true`, expires 2044-07-23. Verified to carry
  `com.apple.application-identifier = ZNHHMX2RP6.com.darkroom.programa`,
  `com.apple.developer.icloud-services = *`, and
  `com.apple.developer.icloud-container-identifiers = [iCloud.com.darkroom.programa]`.
  Stored as the `APPLE_PROVISION_PROFILE_BASE64` GitHub secret.
- iOS App ID `com.darkroom.programa.spike` already had the same container attached, so it
  needed no change — but its profiles were minted *before* the attachment and carry no
  containers. Xcode regenerates them on the next companion build; verify before assuming
  the phone can subscribe.

Two traps worth recording, both of which cost time here:

- **Xcode's Signing & Capabilities editor cannot finish this.** Setting a team on the
  `GhosttyTabs` target makes Xcode attempt an automatic *Development* profile, which fails
  with "Device … isn't registered in your developer account". That error is a dead end, not a
  blocker to solve: Developer ID profiles set `ProvisionsAllDevices`, so no device
  registration is involved. The editor also rewrites ~2,700 lines of `project.pbxproj`, adds
  `CODE_SIGN_ENTITLEMENTS`, and reformats every shared scheme — all of which conflicts with
  this project's post-build `codesign --entitlements` approach and must be reverted.
- **Registering the App ID must happen before the profile.** The profile wizard only lists
  existing App IDs, and `com.darkroom.programa` was not among them.

**Still required, in order:**

3. **Add the entitlement** to `programa.entitlements`
   (`com.apple.developer.icloud-services`, `com.apple.developer.icloud-container-identifiers`)
   in the same change that flips `MobileBridgePush.releaseProvisioningComplete` to `true` —
   not before. Confirm `scripts/verify-provision-profile.sh` reports the profile as present,
   unexpired, and granting exactly those entitlements.
4. **Mandatory launch-test of the *notarized* build before shipping to `main`.** Notarization
   only checks the code signature and scans for malware — it does **not** evaluate whether a
   restricted entitlement matches an embedded profile. AMFI does that check at launch time,
   on-device, every time. A profile/entitlement mismatch signs cleanly, notarizes cleanly,
   staples cleanly, and then the app is silently killed the moment it launches (POSIX 163 —
   this project has hit exactly this failure before, see
   `restricted-entitlements-brick-app` memory). So: download the actual notarized,
   stapled `.dmg` from a **dry-run** workflow_dispatch run (never test straight off `main`'s
   auto-ship), install it, and confirm the app actually launches and CloudKit initializes
   before that commit is allowed to reach `main`.

### The schema does not exist yet, and Production will not create it for you

Verified 2026-07-28 in CloudKit Console: container `iCloud.com.darkroom.programa` contains
exactly one record type, `Users`, in **both** the Development and Production environments.
`AgentStatus` does not exist anywhere. That single fact explains the phone's runtime errors:
querying or subscribing to a record type that has never been defined is rejected with
`CKError 15/2000 "Server Rejected Request"`, which reads like an entitlement or auth problem
and is not one.

Why it will not fix itself once the Mac starts writing:

- **Development auto-creates record types on first save. Production never does.** Production
  schema only ever arrives via *Deploy Schema Changes* from Development. So the Mac's first
  write does not bootstrap it.
- **The Mac writes to Production.** Its Developer ID profile pins
  `com.apple.developer.icloud-container-environment = Production` (confirmed in the embedded
  profile of the notarized dry-run build). So the Mac will hit the same rejection the phone
  does, for the same reason.
- **A Debug phone build reads Development.** Even with the schema deployed, a locally-built
  companion and a Developer-ID Mac are pointed at two different databases and will never see
  each other's records. End-to-end verification needs a Release/TestFlight build of the
  companion, or a deliberately dev-signed Mac writer.

**Required, and deliberately left for a human — deploying schema to Production is not
reversible in the way normal config is.** In CloudKit Console, Development environment,
create record type `AgentStatus` with the fields `MobileBridgePush.performSave` actually
writes (`Sources/MobileBridge/MobileBridgePush.swift:209-221`):

| field | type |
|---|---|
| `blockedCount` | Int64 |
| `workingCount` | Int64 |
| `mostRecentBlockedWorkspaceTitle` | String |

The record name is fixed at `agent-status-summary` (a record ID, not a field). The
`CKQuerySubscription` needs the type queryable, so add the queryable index CloudKit prompts
for. Then *Deploy Schema Changes…* to Production.

Until that is done, no amount of correct entitlement or provisioning makes a notification
arrive. This was invisible before now because `releaseProvisioningComplete` kept the Mac
writer dark, so nothing had ever attempted the first write.

**Known limit — this is an iOS-only bet.** CloudKit cannot serve an Android companion. If
Android happens (plausible if Programa reaches Windows), push gets rebuilt around a relay that
fans out to APNs and FCM. The *transport* generalizes fine — `iroh-ffi` is uniffi-based, so
Kotlin bindings are achievable — only push is platform-locked. Accepted deliberately: pay for
the second path when it is real.

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
