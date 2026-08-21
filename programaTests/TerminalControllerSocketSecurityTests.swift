import XCTest
import AppKit
import Combine
import Darwin

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
final class TerminalControllerSocketSecurityTests: XCTestCase {
    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("csec-\(name.prefix(4))-\(shortID).sock")
            .path
    }

    override func setUp() {
        super.setUp()
        TerminalController.shared.stop()
    }

    override func tearDown() {
        TerminalController.shared.stop()
        super.tearDown()
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    func testClearingEmptyWorkspaceTelemetryDoesNotRepublishWorkspace() async {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true, eagerLoadTerminal: false)
        let socketPath = makeSocketPath("empty-telemetry")

        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        await drainMainQueue()

        workspace.statusEntries["present"] = SidebarStatusEntry(key: "present", value: "running")
        workspace.logEntries = [
            SidebarLogEntry(message: "running", level: .progress, source: nil, timestamp: Date()),
        ]
        workspace.progress = SidebarProgressState(value: 0.5, label: "running")

        var publishCount = 0
        let cancellable = workspace.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        _ = TerminalController.shared.v2WorkspaceClearStatus(params: [
            "workspace_id": workspace.id.uuidString,
            "key": "present",
        ])
        _ = TerminalController.shared.v2WorkspaceClearLog(params: [
            "workspace_id": workspace.id.uuidString,
        ])
        _ = TerminalController.shared.v2WorkspaceClearProgress(params: [
            "workspace_id": workspace.id.uuidString,
        ])
        await drainMainQueue()

        XCTAssertNil(workspace.statusEntries["present"])
        XCTAssertTrue(workspace.logEntries.isEmpty)
        XCTAssertNil(workspace.progress)
        XCTAssertGreaterThanOrEqual(
            publishCount,
            3,
            "Populated clear commands should reach the workspace and publish their removals"
        )

        publishCount = 0

        _ = TerminalController.shared.v2WorkspaceClearStatus(params: [
            "workspace_id": workspace.id.uuidString,
            "key": "missing",
        ])
        _ = TerminalController.shared.v2WorkspaceClearLog(params: [
            "workspace_id": workspace.id.uuidString,
        ])
        _ = TerminalController.shared.v2WorkspaceClearProgress(params: [
            "workspace_id": workspace.id.uuidString,
        ])
        await drainMainQueue()

        XCTAssertEqual(
            publishCount,
            0,
            "Clearing telemetry that is already absent should not invalidate workspace observers"
        )
    }

    /// Regression for #6618: `shouldPublishShellActivity` used to record the state
    /// it was queried with (write-on-read). When a report arrived before the panel
    /// existed, that premature write suppressed every later identical report, so the
    /// panel's shell state stayed `.unknown` forever. The read and the write are now
    /// split — `recordShellActivity` is the only writer and runs only after a
    /// confirmed main-thread apply.
    func testShellActivityDedupDoesNotSuppressWhenApplyWasNeverRecorded() {
        let fastPath = TerminalController.SocketFastPathState()
        let workspaceId = UUID()
        let panelId = UUID()
        let idle = Workspace.PanelShellActivityState.promptIdle

        // First report for this surface must publish.
        XCTAssertTrue(fastPath.shouldPublishShellActivity(
            workspaceId: workspaceId, panelId: panelId, state: idle))

        // The panel was absent, so the apply was never recorded. Querying again must
        // NOT have been suppressed by the previous read (the core of the #6618 bug).
        XCTAssertTrue(fastPath.shouldPublishShellActivity(
            workspaceId: workspaceId, panelId: panelId, state: idle))

        // After a confirmed apply is recorded, the identical report is deduped.
        // recordShellActivity hops a serial queue; the subsequent sync read is FIFO-
        // ordered behind it, so this is deterministic without sleeping.
        fastPath.recordShellActivity(workspaceId: workspaceId, panelId: panelId, state: idle)
        XCTAssertFalse(fastPath.shouldPublishShellActivity(
            workspaceId: workspaceId, panelId: panelId, state: idle))

        // A different state always publishes.
        XCTAssertTrue(fastPath.shouldPublishShellActivity(
            workspaceId: workspaceId, panelId: panelId, state: .commandRunning))
    }

    func testSocketPermissionsFollowAccessMode() throws {
        let tabManager = TabManager()

        let allowAllPath = makeSocketPath("allow-all")
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: allowAllPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: allowAllPath)
        XCTAssertEqual(try socketMode(at: allowAllPath), 0o666)

        TerminalController.shared.stop()

        let restrictedPath = makeSocketPath("cmux-only")
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: restrictedPath,
            accessMode: .cmuxOnly
        )
        try waitForSocket(at: restrictedPath)
        XCTAssertEqual(try socketMode(at: restrictedPath), 0o600)
    }

    func testPasswordModeRejectsUnauthenticatedCommands() throws {
        let socketPath = makeSocketPath("password-mode")
        let tabManager = TabManager()

        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .password
        )
        try waitForSocket(at: socketPath)

        let pingOnly = try sendCommands(["ping"], to: socketPath)
        XCTAssertEqual(pingOnly.count, 1)
        XCTAssertTrue(pingOnly[0].hasPrefix("ERROR:"))
        XCTAssertFalse(pingOnly[0].localizedCaseInsensitiveContains("PONG"))

        let wrongAuthThenPing = try sendCommands(
            ["auth not-the-password", "ping"],
            to: socketPath
        )
        XCTAssertEqual(wrongAuthThenPing.count, 2)
        XCTAssertTrue(wrongAuthThenPing[0].hasPrefix("ERROR:"))
        XCTAssertTrue(wrongAuthThenPing[1].hasPrefix("ERROR:"))
    }

    func testSocketCommandPolicyDistinguishesFocusIntent() throws {
#if DEBUG
        // The v1 line protocol was removed: isV2: false is now unreachable from any real
        // socket command (only v2 JSON-RPC is dispatched), and always denies focus
        // mutation regardless of commandKey — verify that fallback explicitly.
        let nonFocus = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "ping",
            isV2: false
        )
        XCTAssertTrue(nonFocus.insideSuppressed)
        XCTAssertFalse(nonFocus.insideAllowsFocus)
        XCTAssertFalse(nonFocus.outsideSuppressed)
        XCTAssertFalse(nonFocus.outsideAllowsFocus)

        let windowFocus = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "window.focus",
            isV2: true
        )
        XCTAssertTrue(windowFocus.insideSuppressed)
        XCTAssertTrue(windowFocus.insideAllowsFocus)
        XCTAssertFalse(windowFocus.outsideSuppressed)

        let focusV2 = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "workspace.select",
            isV2: true
        )
        XCTAssertTrue(focusV2.insideSuppressed)
        XCTAssertTrue(focusV2.insideAllowsFocus)
        XCTAssertFalse(focusV2.outsideSuppressed)

        let moveWorkspace = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "workspace.move_to_window",
            isV2: true
        )
        XCTAssertTrue(moveWorkspace.insideSuppressed)
        XCTAssertFalse(moveWorkspace.insideAllowsFocus)

        let triggerFlash = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "surface.trigger_flash",
            isV2: true
        )
        XCTAssertTrue(triggerFlash.insideSuppressed)
        XCTAssertFalse(triggerFlash.insideAllowsFocus)

        let simulateShortcut = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "debug.shortcut.simulate",
            isV2: true
        )
        XCTAssertTrue(simulateShortcut.insideSuppressed)
        XCTAssertFalse(simulateShortcut.insideAllowsFocus)

        let settingsOpen = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "settings.open",
            isV2: true
        )
        XCTAssertTrue(settingsOpen.insideSuppressed)
        XCTAssertFalse(settingsOpen.insideAllowsFocus)

        let feedbackOpen = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "feedback.open",
            isV2: true
        )
        XCTAssertTrue(feedbackOpen.insideSuppressed)
        XCTAssertFalse(feedbackOpen.insideAllowsFocus)

        let debugType = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "debug.type",
            isV2: true
        )
        XCTAssertTrue(debugType.insideSuppressed)
        XCTAssertFalse(debugType.insideAllowsFocus)
#else
        throw XCTSkip("Socket command policy snapshot helper is debug-only.")
#endif
    }

    func testRemoteStatusPayloadOmitsSensitiveSSHConfiguration() {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: false, eagerLoadTerminal: false)

        workspace.configureRemoteConnection(
            .init(
                destination: "example.com",
                port: 2222,
                identityFile: "/Users/test/.ssh/id_ed25519",
                sshOptions: ["ControlMaster=auto", "ControlPersist=600"],
                localProxyPort: 1080,
                relayPort: 4444,
                relayID: "relay-id",
                relayToken: "relay-token",
                localSocketPath: "/tmp/programa-test.sock",
                terminalStartupCommand: "ssh example.com"
            ),
            autoConnect: false
        )

        let payload = workspace.remoteStatusPayload()
        XCTAssertNil(payload["identity_file"])
        XCTAssertNil(payload["ssh_options"])
        XCTAssertEqual(payload["has_identity_file"] as? Bool, true)
        XCTAssertEqual(payload["has_ssh_options"] as? Bool, true)
    }

    func testNotificationCreateUsesExplicitSurfaceIDWhenProvided() async throws {
        let socketPath = makeSocketPath("notify-surface")
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }
        guard let targetPanel = workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }
        workspace.focusPanel(focusedPanelId)

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendV2Request(
                        method: "notification.create",
                        params: [
                            "workspace_id": workspace.id.uuidString,
                            "surface_id": targetPanel.id.uuidString,
                            "title": "Targeted"
                        ],
                        to: socketPath
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(result["surface_id"] as? String, targetPanel.id.uuidString)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: targetPanel.id))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    /// Regression for #82: `surface.report_tty`/`surface.ports_kick` used to block the socket
    /// thread with `DispatchQueue.main.sync` so the response could echo the surface resolved on
    /// main (e.g. falling back to the focused surface when `surface_id` is omitted). They now
    /// follow the same off-main-parse + main.async-mutate telemetry shape as
    /// `workspace.set_status`/`workspace.report_meta_block`: the JSON-RPC response acknowledges
    /// immediately (echoing the request, not a value resolved on main) and the surface-resolving
    /// model mutation is fire-and-forget.
    func testSurfaceRelayRPCsAcknowledgeImmediatelyAndResolveFocusedSurfaceAsync() async throws {
        let socketPath = makeSocketPath("relay-fallback")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)

        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let reportTTYResponse = try await sendV2RequestAsync(
            method: "surface.report_tty",
            params: [
                "workspace_id": workspace.id.uuidString,
                "tty_name": "ttys999"
            ],
            to: socketPath
        )

        XCTAssertEqual(reportTTYResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(reportTTYResponse)")
        let reportTTYResult = try XCTUnwrap(reportTTYResponse["result"] as? [String: Any], "Unexpected JSON-RPC response: \(reportTTYResponse)")
        // surface_id was omitted from the request, so the immediate ack echoes null — the actual
        // surface is resolved asynchronously on main.
        XCTAssertNil(reportTTYResult["surface_id"] as? String)
        XCTAssertTrue(waitUntil { workspace.surfaceTTYNames[focusedPanelId] == "ttys999" },
                      "Expected fire-and-forget mutation to eventually register the TTY on the focused surface")

        let portsKickResponse = try await sendV2RequestAsync(
            method: "surface.ports_kick",
            params: ["workspace_id": workspace.id.uuidString],
            to: socketPath
        )

        XCTAssertEqual(portsKickResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(portsKickResponse)")
        _ = try XCTUnwrap(portsKickResponse["result"] as? [String: Any], "Unexpected JSON-RPC response: \(portsKickResponse)")
    }

    func testSurfaceRelayRPCsAcknowledgeImmediatelyAndNoOpForUnknownSurfaceID() async throws {
        let socketPath = makeSocketPath("relay-invalid")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)

        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let unknownSurfaceId = UUID()

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let reportTTYResponse = try await sendV2RequestAsync(
            method: "surface.report_tty",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": unknownSurfaceId.uuidString,
                "tty_name": "ttys999"
            ],
            to: socketPath
        )

        // The unknown surface_id can no longer be validated synchronously (that check now
        // happens inside the fire-and-forget main.async mutation), so the request is acked
        // immediately and the mutation silently no-ops once it resolves.
        XCTAssertEqual(reportTTYResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(reportTTYResponse)")
        let reportTTYResult = try XCTUnwrap(reportTTYResponse["result"] as? [String: Any], "Unexpected JSON-RPC response: \(reportTTYResponse)")
        XCTAssertEqual(reportTTYResult["surface_id"] as? String, unknownSurfaceId.uuidString)

        let portsKickResponse = try await sendV2RequestAsync(
            method: "surface.ports_kick",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": unknownSurfaceId.uuidString
            ],
            to: socketPath
        )

        XCTAssertEqual(portsKickResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(portsKickResponse)")
        let portsKickResult = try XCTUnwrap(portsKickResponse["result"] as? [String: Any], "Unexpected JSON-RPC response: \(portsKickResponse)")
        XCTAssertEqual(portsKickResult["surface_id"] as? String, unknownSurfaceId.uuidString)

        // Give the async mutation a beat to run, then confirm it never registered a TTY for the
        // nonexistent surface.
        waitUntil(timeout: 0.5) { false }
        XCTAssertTrue(workspace.surfaceTTYNames.isEmpty)
    }

    func testWorkspaceCloseRejectsPinnedWorkspace() async throws {
        let socketPath = makeSocketPath("close-pinned")
        let manager = TabManager()
        let pinnedWorkspace = manager.addWorkspace(select: false)
        manager.setPinned(pinnedWorkspace, pinned: true)

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendV2Request(
                        method: "workspace.close",
                        params: ["workspace_id": pinnedWorkspace.id.uuidString],
                        to: socketPath
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(error["code"] as? String, "protected")

        let data = try XCTUnwrap(error["data"] as? [String: Any], "Expected error data payload")
        XCTAssertEqual(data["workspace_id"] as? String, pinnedWorkspace.id.uuidString)
        XCTAssertEqual(data["pinned"] as? Bool, true)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == pinnedWorkspace.id }))
    }

    func testSocketPreservesRequestIDWhenUTF8ScalarSpansReads() throws {
        let socketPath = makeSocketPath("split-utf8")
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let fd = try connect(to: socketPath)
        defer { Darwin.close(fd) }

        let requestID = "request-🐈"
        let request = #"{"jsonrpc":"2.0","id":"request-🐈","method":"system.ping","params":{}}"#
        let bytes = Array((request + "\n").utf8)
        let emojiBytes = Array("🐈".utf8)
        let emojiStart = try XCTUnwrap(
            bytes.indices.first { index in
                index + emojiBytes.count <= bytes.count &&
                    Array(bytes[index..<(index + emojiBytes.count)]) == emojiBytes
            }
        )
        let splitIndex = emojiStart + 2

        let firstWrite = bytes.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress, splitIndex)
        }
        XCTAssertEqual(firstWrite, splitIndex)
        // Give the listener time to consume the first syscall before completing the scalar.
        // Without this gap, the kernel may coalesce both writes into one read and stop the test
        // from exercising the framing boundary that caused the regression.
        usleep(50_000)
        let secondWrite = bytes.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress!.advanced(by: splitIndex), bytes.count - splitIndex)
        }
        XCTAssertEqual(secondWrite, bytes.count - splitIndex)

        let responseData = Data(try readLine(from: fd).utf8)
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(
            response["id"] as? String,
            requestID,
            "A valid request identifier must survive when the kernel splits a UTF-8 scalar across reads"
        )
    }

    func testSocketRejectsInvalidUTF8AndClosesConnection() throws {
        let socketPath = makeSocketPath("invalid-utf8")
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let fd = try connect(to: socketPath)
        defer { Darwin.close(fd) }

        let invalidFrame = Array(#"{"jsonrpc":"2.0","id":""#.utf8) +
            [0xF0, 0x28, 0x8C, 0x28] +
            Array(#"","method":"system.ping","params":{}}"#.utf8) + [0x0A]
        let wrote = invalidFrame.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress, invalidFrame.count)
        }
        XCTAssertEqual(wrote, invalidFrame.count)

        let responseData = Data(try readLine(from: fd).utf8)
        let response = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_utf8")

        var byte: UInt8 = 0
        try waitForReadable(
            from: fd,
            until: .now() + 5.0,
            operation: "waiting for the invalid-UTF-8 connection to close"
        )
        let closeRead = Darwin.read(fd, &byte, 1)
        guard closeRead >= 0 else { throw posixError("read after invalid UTF-8") }
        XCTAssertEqual(
            closeRead,
            0,
            "Invalid UTF-8 is a framing error, so the server must close instead of parsing later bytes on the connection"
        )
    }

    func testWorkspaceTelemetryEnforcesPayloadAndCollectionBoundsThroughSocket() async throws {
        let socketPath = makeSocketPath("telemetry-limits")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let acceptedPayloads: [(method: String, field: String, limit: Int)] = [
            ("workspace.set_status", "value", SidebarTelemetryLimits.maxStatusValueBytes),
            ("workspace.log", "message", SidebarTelemetryLimits.maxLogMessageBytes),
            ("workspace.report_meta_block", "markdown", SidebarTelemetryLimits.maxMetadataMarkdownBytes),
        ]
        for target in acceptedPayloads {
            let payload = String(repeating: "x", count: target.limit)
            var params: [String: Any] = [
                "workspace_id": workspace.id.uuidString,
                target.field: payload,
            ]
            if target.method != "workspace.log" {
                params["key"] = "boundary-\(target.field)"
            }
            let response = try await sendV2RequestAsync(method: target.method, params: params, to: socketPath)
            XCTAssertEqual(
                response["ok"] as? Bool,
                true,
                "The documented maximum UTF-8 payload must remain accepted for \(target.method): \(response)"
            )

            params[target.field] = payload + "x"
            let oversized = try await sendV2RequestAsync(method: target.method, params: params, to: socketPath)
            XCTAssertEqual(oversized["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(oversized)")
            let error = try XCTUnwrap(oversized["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_params")
        }

        let oversizedURLPrefix = "https://example.com/"
        let oversizedAuxiliaryFields: [(method: String, field: String, value: String)] = [
            ("workspace.set_status", "key", String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes + 1)),
            ("workspace.set_status", "icon", String(repeating: "i", count: SidebarTelemetryLimits.maxStatusIconBytes + 1)),
            ("workspace.set_status", "color", String(repeating: "c", count: SidebarTelemetryLimits.maxStatusColorBytes + 1)),
            (
                "workspace.set_status",
                "url",
                oversizedURLPrefix + String(
                    repeating: "u",
                    count: SidebarTelemetryLimits.maxStatusURLBytes - oversizedURLPrefix.utf8.count + 1
                )
            ),
            ("workspace.log", "source", String(repeating: "s", count: SidebarTelemetryLimits.maxLogSourceBytes + 1)),
            ("workspace.report_meta_block", "key", String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes + 1)),
        ]
        for target in oversizedAuxiliaryFields {
            var params: [String: Any] = ["workspace_id": workspace.id.uuidString]
            switch target.method {
            case "workspace.set_status":
                params["key"] = "aux-status"
                params["value"] = "ok"
            case "workspace.log":
                params["message"] = "ok"
            default:
                params["key"] = "aux-metadata"
                params["markdown"] = "ok"
            }
            params[target.field] = target.value

            let response = try await sendV2RequestAsync(method: target.method, params: params, to: socketPath)
            XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_params")
            XCTAssertTrue(
                (error["message"] as? String)?.contains(target.field) == true,
                "The validation error must identify the oversized \(target.field): \(response)"
            )
        }

        let surfaceId = UUID()
        let exactTTYName = String(repeating: "t", count: SidebarTelemetryLimits.maxTTYNameBytes)
        let acceptedTTY = try await sendV2RequestAsync(
            method: "surface.report_tty",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceId.uuidString,
                "tty_name": exactTTYName,
            ],
            to: socketPath
        )
        XCTAssertEqual(acceptedTTY["ok"] as? Bool, true, "The maximum TTY name must remain accepted: \(acceptedTTY)")

        let pullRequestURL = "https://example.com/pull/1"
        let oversizedPullRequestURL = oversizedURLPrefix + String(
            repeating: "u",
            count: SidebarTelemetryLimits.maxPullRequestURLBytes - oversizedURLPrefix.utf8.count + 1
        )
        let oversizedRetainedFields: [(method: String, field: String, limit: Int, params: [String: Any])] = [
            (
                "surface.report_pwd",
                "path",
                SidebarTelemetryLimits.maxDirectoryBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "path": String(repeating: "p", count: SidebarTelemetryLimits.maxDirectoryBytes + 1),
                ]
            ),
            (
                "surface.report_git_branch",
                "branch",
                SidebarTelemetryLimits.maxGitBranchBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "branch": String(repeating: "b", count: SidebarTelemetryLimits.maxGitBranchBytes + 1),
                ]
            ),
            (
                "surface.report_pr",
                "url",
                SidebarTelemetryLimits.maxPullRequestURLBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "number": 1,
                    "url": oversizedPullRequestURL,
                ]
            ),
            (
                "surface.report_pr",
                "branch",
                SidebarTelemetryLimits.maxGitBranchBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "number": 1,
                    "url": pullRequestURL,
                    "branch": String(repeating: "b", count: SidebarTelemetryLimits.maxGitBranchBytes + 1),
                ]
            ),
            (
                "surface.report_pr",
                "label",
                SidebarTelemetryLimits.maxPullRequestLabelBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "number": 1,
                    "url": pullRequestURL,
                    // Sixteen grapheme clusters pass the UI character truncation but exceed 64 UTF-8 bytes.
                    "label": String(repeating: "👨‍👩‍👧‍👦", count: 16),
                ]
            ),
            (
                "workspace.set_progress",
                "label",
                SidebarTelemetryLimits.maxProgressLabelBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "value": 0.5,
                    "label": String(repeating: "l", count: SidebarTelemetryLimits.maxProgressLabelBytes + 1),
                ]
            ),
            (
                "surface.report_tty",
                "tty_name",
                SidebarTelemetryLimits.maxTTYNameBytes,
                [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": surfaceId.uuidString,
                    "tty_name": exactTTYName + "t",
                ]
            ),
        ]
        for target in oversizedRetainedFields {
            let response = try await sendV2RequestAsync(method: target.method, params: target.params, to: socketPath)
            XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_params")
            let message = try XCTUnwrap(error["message"] as? String)
            XCTAssertTrue(message.contains(target.field), "The validation error must identify \(target.field): \(response)")
            XCTAssertTrue(message.contains(String(target.limit)), "The validation error must identify the byte limit: \(response)")
        }

        let hostlessPullRequest = try await sendV2RequestAsync(
            method: "surface.report_pr",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceId.uuidString,
                "number": 1,
                "url": "https:///missing-host",
            ],
            to: socketPath
        )
        XCTAssertEqual(hostlessPullRequest["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(hostlessPullRequest)")
        let hostlessError = try XCTUnwrap(hostlessPullRequest["error"] as? [String: Any])
        XCTAssertEqual(hostlessError["code"] as? String, "invalid_params")

        workspace.statusEntries.removeAll()
        workspace.metadataBlocks.removeAll()
        workspace.agentPIDs.removeAll()
        let oldTimestamp = Date(timeIntervalSince1970: 1)
        for index in 0..<SidebarTelemetryLimits.maxStatusEntries {
            workspace.statusEntries["old-status-\(index)"] = SidebarStatusEntry(
                key: "old-status-\(index)",
                value: "old",
                timestamp: oldTimestamp.addingTimeInterval(TimeInterval(index))
            )
        }
        workspace.agentPIDs["old-status-0"] = 101
        workspace.agentPIDs["old-status-1"] = 102
        let newestStatusKey = "new-status"
        let statusResponse = try await sendV2RequestAsync(
            method: "workspace.set_status",
            params: [
                "workspace_id": workspace.id.uuidString,
                "key": newestStatusKey,
                "value": "new",
                "pid": 303,
            ],
            to: socketPath
        )
        XCTAssertEqual(statusResponse["ok"] as? Bool, true)
        XCTAssertTrue(waitUntil {
            workspace.statusEntries.count == SidebarTelemetryLimits.maxStatusEntries &&
                workspace.statusEntries[newestStatusKey] != nil &&
                workspace.agentPIDs["old-status-0"] == nil &&
                workspace.agentPIDs[newestStatusKey] == 303
        })
        XCTAssertNil(workspace.statusEntries["old-status-0"], "The oldest status must be evicted at the collection bound")
        XCTAssertEqual(workspace.agentPIDs["old-status-1"], 102, "Eviction must preserve PID state for retained statuses")

        for index in 0..<SidebarTelemetryLimits.maxMetadataBlocks {
            workspace.metadataBlocks["old-meta-\(index)"] = SidebarMetadataBlock(
                key: "old-meta-\(index)",
                markdown: "old",
                priority: 0,
                timestamp: oldTimestamp.addingTimeInterval(TimeInterval(index))
            )
        }
        let newestMetadataKey = "new-meta"
        let metadataResponse = try await sendV2RequestAsync(
            method: "workspace.report_meta_block",
            params: [
                "workspace_id": workspace.id.uuidString,
                "key": newestMetadataKey,
                "markdown": "new",
            ],
            to: socketPath
        )
        XCTAssertEqual(metadataResponse["ok"] as? Bool, true)
        XCTAssertTrue(waitUntil {
            workspace.metadataBlocks.count == SidebarTelemetryLimits.maxMetadataBlocks &&
                workspace.metadataBlocks[newestMetadataKey] != nil
        })
        XCTAssertNil(workspace.metadataBlocks["old-meta-0"], "The oldest metadata block must be evicted at the collection bound")
    }

    func testWorkspaceAgentPIDCommandsEnforceIntegerAndKeyBounds() async throws {
        let socketPath = makeSocketPath("agent-pid-limits")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let oversizedPID = Int(pid_t.max) + 1
        let oversizedKey = String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes + 1)
        let rejectedRequests: [(method: String, params: [String: Any])] = [
            (
                "workspace.set_agent_pid",
                ["workspace_id": workspace.id.uuidString, "key": "zero", "pid": 0]
            ),
            (
                "workspace.set_agent_pid",
                ["workspace_id": workspace.id.uuidString, "key": "overflow", "pid": oversizedPID]
            ),
            (
                "workspace.set_agent_pid",
                ["workspace_id": workspace.id.uuidString, "key": oversizedKey, "pid": 1]
            ),
            (
                "workspace.clear_agent_pid",
                ["workspace_id": workspace.id.uuidString, "key": oversizedKey]
            ),
            (
                "workspace.set_status",
                ["workspace_id": workspace.id.uuidString, "key": "status-zero", "value": "ok", "pid": 0]
            ),
            (
                "workspace.set_status",
                ["workspace_id": workspace.id.uuidString, "key": "status-invalid", "value": "ok", "pid": "invalid"]
            ),
            (
                "workspace.set_status",
                ["workspace_id": workspace.id.uuidString, "key": "status-overflow", "value": "ok", "pid": oversizedPID]
            ),
        ]
        for request in rejectedRequests {
            let response = try await sendV2RequestAsync(
                method: request.method,
                params: request.params,
                to: socketPath
            )
            XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_params")
        }

        let accepted = try await sendV2RequestAsync(
            method: "workspace.set_agent_pid",
            params: [
                "workspace_id": workspace.id.uuidString,
                "key": "maximum",
                "pid": Int(pid_t.max),
            ],
            to: socketPath
        )
        XCTAssertEqual(accepted["ok"] as? Bool, true, "The maximum pid_t value must remain accepted: \(accepted)")
        XCTAssertTrue(waitUntil { workspace.agentPIDs["maximum"] == pid_t.max })
    }

    func testWorkspaceTelemetryModelRejectsOversizedAuxiliaryFields() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let oversizedURLPrefix = "https://example.com/"
        let oversizedURL = try XCTUnwrap(URL(string:
            oversizedURLPrefix + String(
                repeating: "u",
                count: SidebarTelemetryLimits.maxStatusURLBytes - oversizedURLPrefix.utf8.count + 1
            )
        ))
        let oversizedStatusEntries = [
            SidebarStatusEntry(
                key: String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes + 1),
                value: "ok"
            ),
            SidebarStatusEntry(
                key: "oversized-icon",
                value: "ok",
                icon: String(repeating: "i", count: SidebarTelemetryLimits.maxStatusIconBytes + 1)
            ),
            SidebarStatusEntry(
                key: "oversized-color",
                value: "ok",
                color: String(repeating: "c", count: SidebarTelemetryLimits.maxStatusColorBytes + 1)
            ),
            SidebarStatusEntry(key: "oversized-url", value: "ok", url: oversizedURL),
        ]
        for entry in oversizedStatusEntries {
            XCTAssertFalse(workspace.setSidebarStatusEntry(entry).inserted)
        }
        XCTAssertTrue(workspace.statusEntries.isEmpty)

        XCTAssertFalse(workspace.setSidebarMetadataBlock(SidebarMetadataBlock(
            key: String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes + 1),
            markdown: "ok",
            priority: 0,
            timestamp: Date()
        )))
        XCTAssertTrue(workspace.metadataBlocks.isEmpty)

        XCTAssertFalse(workspace.appendSidebarLogEntry(SidebarLogEntry(
            message: "ok",
            level: .info,
            source: String(repeating: "s", count: SidebarTelemetryLimits.maxLogSourceBytes + 1),
            timestamp: Date()
        )))
        XCTAssertTrue(workspace.logEntries.isEmpty)

        let panelId = UUID()
        let exactDirectory = String(repeating: "d", count: SidebarTelemetryLimits.maxDirectoryBytes)
        workspace.updatePanelDirectory(panelId: panelId, directory: exactDirectory)
        XCTAssertEqual(workspace.panelDirectories[panelId], exactDirectory)
        workspace.updatePanelDirectory(
            panelId: panelId,
            directory: String(repeating: "d", count: SidebarTelemetryLimits.maxDirectoryBytes + 1)
        )
        workspace.updatePanelDirectory(panelId: panelId, directory: "   ")
        XCTAssertEqual(workspace.panelDirectories[panelId], exactDirectory)

        let exactBranch = String(repeating: "b", count: SidebarTelemetryLimits.maxGitBranchBytes)
        workspace.updatePanelGitBranch(panelId: panelId, branch: exactBranch, isDirty: false)
        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, exactBranch)
        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: String(repeating: "b", count: SidebarTelemetryLimits.maxGitBranchBytes + 1),
            isDirty: true
        )
        workspace.updatePanelGitBranch(panelId: panelId, branch: "   ", isDirty: true)
        XCTAssertEqual(workspace.panelGitBranches[panelId], SidebarGitBranchState(branch: exactBranch, isDirty: false))

        let pullRequestURLPrefix = "https://example.com/"
        let exactPullRequestURL = try XCTUnwrap(URL(string:
            pullRequestURLPrefix + String(
                repeating: "u",
                count: SidebarTelemetryLimits.maxPullRequestURLBytes - pullRequestURLPrefix.utf8.count
            )
        ))
        XCTAssertEqual(exactPullRequestURL.absoluteString.utf8.count, SidebarTelemetryLimits.maxPullRequestURLBytes)
        let exactLabel = String(repeating: "l", count: SidebarTelemetryLimits.maxPullRequestLabelBytes)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 1,
            label: exactLabel,
            url: exactPullRequestURL,
            status: .open,
            branch: exactBranch
        )
        XCTAssertEqual(workspace.panelPullRequests[panelId]?.label, exactLabel)
        XCTAssertEqual(workspace.panelPullRequests[panelId]?.url, exactPullRequestURL)
        XCTAssertEqual(workspace.panelPullRequests[panelId]?.branch, exactBranch)

        let retainedPullRequest = workspace.panelPullRequests[panelId]
        let oversizedPullRequestURL = try XCTUnwrap(URL(string:
            pullRequestURLPrefix + String(
                repeating: "u",
                count: SidebarTelemetryLimits.maxPullRequestURLBytes - pullRequestURLPrefix.utf8.count + 1
            )
        ))
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2,
            label: String(repeating: "l", count: SidebarTelemetryLimits.maxPullRequestLabelBytes + 1),
            url: exactPullRequestURL,
            status: .open,
            branch: exactBranch
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2,
            label: "PR",
            url: oversizedPullRequestURL,
            status: .open,
            branch: exactBranch
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2,
            label: "PR",
            url: exactPullRequestURL,
            status: .open,
            branch: String(repeating: "b", count: SidebarTelemetryLimits.maxGitBranchBytes + 1)
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2,
            label: "PR",
            url: try XCTUnwrap(URL(string: "https:///missing-host")),
            status: .open,
            branch: exactBranch
        )
        XCTAssertEqual(workspace.panelPullRequests[panelId], retainedPullRequest)

        let exactProgressLabel = String(repeating: "p", count: SidebarTelemetryLimits.maxProgressLabelBytes)
        XCTAssertTrue(workspace.setSidebarProgress(value: 1.0, label: exactProgressLabel))
        XCTAssertEqual(workspace.progress, SidebarProgressState(value: 1.0, label: exactProgressLabel))
        XCTAssertFalse(workspace.setSidebarProgress(
            value: 0.5,
            label: String(repeating: "p", count: SidebarTelemetryLimits.maxProgressLabelBytes + 1)
        ))
        XCTAssertFalse(workspace.setSidebarProgress(value: -.infinity, label: nil))
        XCTAssertFalse(workspace.setSidebarProgress(value: 1.01, label: nil))
        XCTAssertEqual(workspace.progress, SidebarProgressState(value: 1.0, label: exactProgressLabel))

        let exactTTYName = String(repeating: "t", count: SidebarTelemetryLimits.maxTTYNameBytes)
        XCTAssertTrue(workspace.setSidebarTTYName(panelId: panelId, ttyName: exactTTYName))
        XCTAssertEqual(workspace.surfaceTTYNames[panelId], exactTTYName)
        XCTAssertFalse(workspace.setSidebarTTYName(panelId: panelId, ttyName: exactTTYName + "t"))
        XCTAssertEqual(workspace.surfaceTTYNames[panelId], exactTTYName)

        let exactPIDKey = String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes)
        XCTAssertTrue(workspace.setSidebarAgentPID(key: exactPIDKey, pid: pid_t.max))
        XCTAssertEqual(workspace.agentPIDs.removeValue(forKey: exactPIDKey), pid_t.max)
        XCTAssertFalse(workspace.setSidebarAgentPID(
            key: String(repeating: "k", count: SidebarTelemetryLimits.maxKeyBytes + 1),
            pid: 1
        ))
        XCTAssertFalse(workspace.setSidebarAgentPID(key: "zero", pid: 0))

        for index in 0..<SidebarTelemetryLimits.maxAgentPIDs {
            XCTAssertTrue(workspace.setSidebarAgentPID(key: "agent-\(index)", pid: pid_t(index + 1)))
        }
        XCTAssertEqual(workspace.agentPIDs.count, SidebarTelemetryLimits.maxAgentPIDs)
        XCTAssertFalse(workspace.setSidebarAgentPID(key: "overflow", pid: 1))
        XCTAssertTrue(workspace.setSidebarAgentPID(key: "agent-0", pid: pid_t.max))
        XCTAssertEqual(workspace.agentPIDs["agent-0"], pid_t.max)
        XCTAssertEqual(workspace.agentPIDs.count, SidebarTelemetryLimits.maxAgentPIDs)

        let exactDiagnostic = String(repeating: "e", count: SidebarTelemetryLimits.maxLogMessageBytes)
        workspace.applyRemoteConnectionStateUpdate(.connecting, detail: exactDiagnostic, target: "example")
        XCTAssertEqual(workspace.remoteConnectionDetail, exactDiagnostic)
        workspace.applyRemoteConnectionStateUpdate(.connecting, detail: exactDiagnostic + "e", target: "example")
        XCTAssertEqual(workspace.remoteConnectionDetail, exactDiagnostic)

        workspace.applyRemoteDaemonStatusUpdate(
            WorkspaceRemoteDaemonStatus(state: .ready, detail: exactDiagnostic + "e"),
            target: "example"
        )
        XCTAssertEqual(workspace.remoteDaemonStatus.detail, exactDiagnostic)
    }

    private func waitForSocket(at path: String, timeout: TimeInterval = 5.0) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: path)
            },
            object: NSObject()
        )
        if XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed {
            return
        }
        XCTFail("Timed out waiting for socket at \(path)")
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
    }

    /// Polls `condition` on the main run loop until it returns true or `timeout` elapses.
    /// Used to observe fire-and-forget telemetry mutations (see #82: `surface.report_tty` /
    /// `surface.ports_kick` schedule their model mutation via `DispatchQueue.main.async` and
    /// acknowledge the JSON-RPC request before it runs).
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5.0, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func socketMode(at path: String) throws -> UInt16 {
        var fileInfo = stat()
        guard lstat(path, &fileInfo) == 0 else {
            throw posixError("lstat(\(path))")
        }
        return UInt16(fileInfo.st_mode & 0o777)
    }

    private func sendCommands(_ commands: [String], to socketPath: String) throws -> [String] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(AF_UNIX)")
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(socketPath.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < maxPathLen else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let cPath = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
            cPath.initialize(repeating: 0, count: maxPathLen)
            for (index, byte) in bytes.enumerated() {
                cPath[index] = CChar(bitPattern: byte)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            throw posixError("connect(\(socketPath))")
        }

        var responses: [String] = []
        for command in commands {
            try writeLine(command, to: fd)
            responses.append(try readLine(from: fd))
        }
        return responses
    }

    private nonisolated func sendV2Request(
        method: String,
        params: [String: Any],
        to socketPath: String
    ) throws -> [String: Any] {
        let fd = try connect(to: socketPath)
        defer { Darwin.close(fd) }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode JSON-RPC request"
            ])
        }
        try writeLine(line, to: fd)

        let responseLine = try readLine(from: fd)
        let responseData = Data(responseLine.utf8)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            "Expected JSON-RPC response object"
        )
    }

    private func sendV2RequestAsync(
        method: String,
        params: [String: Any],
        to socketPath: String
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendV2Request(
                        method: method,
                        params: params,
                        to: socketPath
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated func connect(to socketPath: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(AF_UNIX)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(socketPath.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < maxPathLen else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let cPath = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
            cPath.initialize(repeating: 0, count: maxPathLen)
            for (index, byte) in bytes.enumerated() {
                cPath[index] = CChar(bitPattern: byte)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            let error = posixError("connect(\(socketPath))")
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private nonisolated func writeLine(_ command: String, to fd: Int32) throws {
        let payload = Array((command + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let wrote = payload.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            guard wrote >= 0 else {
                throw posixError("write(\(command))")
            }
            offset += wrote
        }
    }

    private nonisolated func readLine(from fd: Int32, timeout: TimeInterval = 5.0) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 1)
        var data = Data()
        let deadline = DispatchTime.now() + timeout

        while true {
            try waitForReadable(from: fd, until: deadline, operation: "waiting for a socket response line")
            let count = Darwin.read(fd, &buffer, 1)
            guard count >= 0 else {
                throw posixError("read")
            }
            if count == 0 { break }
            if buffer[0] == 0x0A { break }
            data.append(buffer[0])
        }

        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Invalid UTF-8 response from socket"
            ])
        }
        return line
    }

    private nonisolated func waitForReadable(
        from fd: Int32,
        until deadline: DispatchTime,
        operation: String
    ) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ETIMEDOUT),
                    userInfo: [NSLocalizedDescriptionKey: "Timed out \(operation)"]
                )
            }
            let remainingNanoseconds = deadline.uptimeNanoseconds - now
            let remainingMilliseconds = max(1, (remainingNanoseconds + 999_999) / 1_000_000)
            let pollTimeout = Int32(min(UInt64(Int32.max), remainingMilliseconds))
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, pollTimeout)
            if result > 0 { return }
            if result == 0 { continue }
            if errno == EINTR { continue }
            throw posixError("poll while \(operation)")
        }
    }

    private nonisolated func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }

    // MARK: - Session escrow: SIGPIPE-safe retrieve-response send (issue #182)

    /// Regression for a real relaunch incident: the escrow holder
    /// (`SessionEscrowHolder.handleRetrieveRequest`) can finish stopping a
    /// session's drain thread (bounded by `SessionEscrowPolicy
    /// .retrieveDrainStopTimeout`, 3s) after the app-side client has
    /// already given up waiting and closed its end of the connection (see
    /// `SessionEscrowPolicy.retrieveRecvTimeout`'s invariant comment).
    /// Writing the retrieve-response frame into that now-peer-closed
    /// connection raises `SIGPIPE` unless the accepted socket has
    /// `SO_NOSIGPIPE` set -- default disposition kills the WHOLE holder
    /// process, dropping every OTHER escrowed session it still holds, not
    /// just the one send that failed.
    ///
    /// This reproduces the exact primitive sequence
    /// `SessionEscrowHolder.run()`'s accept loop uses
    /// (`UnixDomainFDPassing.bindListening` -> `.connect` -> raw
    /// `accept()` -> `UnixDomainFDPassing.suppressSigPipe(on:)`) against a
    /// peer that has already hung up, and asserts the send fails cleanly
    /// (`false`, `EPIPE`) rather than crashing. Confirmed separately
    /// (outside this test, not committed) that omitting the
    /// `suppressSigPipe` call reproduces a hard process crash (terminated
    /// by `SIGPIPE`) on this exact sequence -- deliberately not exercised
    /// as a literal "red without the fix" commit here, since a crash would
    /// take down the entire shared XCTest process for this whole test
    /// bundle, not just this one test method.
    func testEscrowRetrieveResponseSendSurvivesClosedPeerWithoutCrashing() {
        let socketPath = makeSocketPath("escrow-nosigpipe")
        defer { unlink(socketPath) }

        guard let listenFD = UnixDomainFDPassing.bindListening(socketPath: socketPath) else {
            XCTFail("bindListening failed")
            return
        }
        defer { close(listenFD) }

        guard let clientFD = UnixDomainFDPassing.connect(to: socketPath) else {
            XCTFail("connect failed")
            return
        }

        let acceptedFD = accept(listenFD, nil, nil)
        guard acceptedFD >= 0 else {
            close(clientFD)
            XCTFail("accept failed")
            return
        }
        defer { close(acceptedFD) }

        // Mirrors `SessionEscrowHolder.run()`'s accept loop exactly: every
        // accepted connection gets `SO_NOSIGPIPE` before it's ever handed
        // to `serve(connectionFD:)`.
        UnixDomainFDPassing.suppressSigPipe(on: acceptedFD)

        // The app-side client abandoning the connection -- `retrieve()`
        // closes its socket via `defer` on every exit path, including a
        // timeout -- so the holder's `acceptedFD` is now writing into a
        // peer that has already hung up.
        close(clientFD)

        guard let frame = EscrowWireFormat.encodeRetrieveResponseFrame(
            sessionId: String(repeating: "a", count: EscrowWireFormat.sessionIdSize),
            granted: false
        ) else {
            XCTFail("failed to encode frame")
            return
        }

        let sendResult = UnixDomainFDPassing.send(fd: nil, payload: frame, over: acceptedFD)

        // Reaching this assertion at all is most of the point -- pre-fix,
        // the process does not survive the `send` call above.
        XCTAssertFalse(sendResult, "send to a closed peer must fail cleanly (EPIPE), not succeed")
    }

    // MARK: - Session escrow: per-socket-path circuit breaker (escrow follow-up #6)

    /// Thread-safe bookkeeping for the background "wedged holder" accept
    /// loop below: it accepts every connection but never responds, so a
    /// `retrieve()` call against it always times out rather than seeing EOF
    /// -- the exact failure mode the circuit breaker exists for.
    private final class AcceptedConnections: @unchecked Sendable {
        private let lock = NSLock()
        private var fds: [Int32] = []

        func append(_ fd: Int32) {
            lock.lock()
            fds.append(fd)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return fds.count
        }

        func closeAll() {
            lock.lock()
            let all = fds
            fds = []
            lock.unlock()
            for fd in all { close(fd) }
        }

        /// Polls (bounded) until the accept thread has recorded at least
        /// `expected` connections, or `timeout` elapses. A plain `count`
        /// read races the accept thread: `retrieve()` returning (its recv
        /// timeout having elapsed) only guarantees the kernel completed the
        /// connection, not that this thread's `accept()` call has returned
        /// and appended the fd yet. Returns whatever count was actually
        /// observed so the caller's assertion message stays meaningful on
        /// a genuine failure.
        func waitForCount(atLeast expected: Int, timeout: TimeInterval = 2.0) -> Int {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let current = count
                if current >= expected || Date() >= deadline {
                    return current
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    /// Regression for the escrow follow-up ("per-socket-path circuit
    /// breaker for wedged holders"): app-launch restore
    /// (`Workspace+Persistence.swift`'s `attemptSessionReattach`) calls
    /// `SessionEscrowClient.retrieve` SERIALLY on the main thread, once per
    /// escrowed panel, and almost every panel shares the SAME deterministic
    /// holder socket path. Without a breaker, N sessions against one
    /// wedged (accepts but never answers) holder would each pay the full
    /// `retrieveRecvTimeout` -- N times the stall for one dead holder.
    ///
    /// This drives a real wedged holder (accepts, never responds) against
    /// an injectable short `recvTimeout` (avoiding the real 5s
    /// `SessionEscrowPolicy.retrieveRecvTimeout`) and asserts: the first
    /// retrieve pays the full timeout and opens the breaker for that path;
    /// a second retrieve against the SAME path returns near-instantly
    /// without attempting a new connection at all (the listener sees no
    /// second connection); and after resetting the breaker, a retrieve
    /// against that path attempts a genuinely fresh connect again.
    func testEscrowRetrieveCircuitBreakerSkipsSecondCallToWedgedHolder() {
        SessionEscrowClient.resetCircuitBreakerForTesting()
        defer { SessionEscrowClient.resetCircuitBreakerForTesting() }

        let socketPath = makeSocketPath("escrow-cb")
        defer { unlink(socketPath) }

        guard let listenFD = UnixDomainFDPassing.bindListening(socketPath: socketPath) else {
            XCTFail("bindListening failed")
            return
        }

        let accepted = AcceptedConnections()
        let holderThread = Thread {
            while true {
                let clientFD = accept(listenFD, nil, nil)
                guard clientFD >= 0 else { break }
                // Wedged: accept the connection but never send a response
                // and never close it -- the client's own recv timeout is
                // the only thing that ever ends this connection.
                accepted.append(clientFD)
            }
        }
        holderThread.start()
        defer {
            close(listenFD) // unblocks the accept() loop so the thread exits
            accepted.closeAll()
        }

        let sessionId = String(repeating: "a", count: EscrowWireFormat.sessionIdSize)
        let tokenHex = String(repeating: "00", count: EscrowWireFormat.tokenSize)
        let shortTimeout: TimeInterval = 0.2

        let firstStart = Date()
        let firstResult = SessionEscrowClient.retrieve(
            sessionId: sessionId,
            tokenHex: tokenHex,
            socketPath: socketPath,
            recvTimeout: shortTimeout
        )
        let firstElapsed = Date().timeIntervalSince(firstStart)
        XCTAssertNil(firstResult, "a wedged holder must never grant a retrieval")
        XCTAssertGreaterThanOrEqual(firstElapsed, shortTimeout, "first retrieve must actually wait out the recv timeout")
        XCTAssertEqual(accepted.waitForCount(atLeast: 1), 1, "the wedged holder must have accepted exactly one connection so far")

        let secondStart = Date()
        let secondResult = SessionEscrowClient.retrieve(
            sessionId: sessionId,
            tokenHex: tokenHex,
            socketPath: socketPath,
            recvTimeout: shortTimeout
        )
        let secondElapsed = Date().timeIntervalSince(secondStart)
        XCTAssertNil(secondResult)
        XCTAssertLessThan(secondElapsed, 0.15, "second retrieve against the same path must be skipped by the open breaker, not pay another timeout (still well under the 0.2s injected timeout)")
        XCTAssertEqual(accepted.count, 1, "an open breaker must prevent a second connection attempt to the wedged holder")

        SessionEscrowClient.resetCircuitBreakerForTesting()

        let thirdStart = Date()
        let thirdResult = SessionEscrowClient.retrieve(
            sessionId: sessionId,
            tokenHex: tokenHex,
            socketPath: socketPath,
            recvTimeout: shortTimeout
        )
        let thirdElapsed = Date().timeIntervalSince(thirdStart)
        XCTAssertNil(thirdResult)
        XCTAssertGreaterThanOrEqual(thirdElapsed, shortTimeout, "after resetting the breaker, retrieve must attempt a genuinely fresh connect")
        XCTAssertEqual(accepted.waitForCount(atLeast: 2), 2, "the reset breaker must allow a new connection attempt, which the holder accepts")
    }

    // MARK: - Revived-session ancestry authorization (#286)

    /// Spawns a live process that is deliberately **not** a descendant of this
    /// one: a short-lived `sh` backgrounds a `sleep` and exits, so the `sleep`
    /// is orphaned and reparented to launchd. That is exactly the shape an
    /// escrow-revived shell has — forked by the previous app process, adopted
    /// by launchd when that process died — which is why its ancestry can never
    /// walk back to us. Returns the orphan's pid, killed again on teardown.
    private func spawnOrphanedProcess() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(text), "could not read the orphan's pid from sh")
        XCTAssertGreaterThan(pid, 1)
        addTeardownBlock { kill(pid, SIGKILL) }

        // The intermediate `sh` has exited, so the orphan is now launchd's.
        // Give the reparent a moment to land before anyone walks the tree.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, TerminalController.shared.isDescendant(pid) {
            usleep(20_000)
        }
        return pid
    }

    func testRevivedRootAuthorizesAPidThatIsNotADescendant() throws {
        let orphan = try spawnOrphanedProcess()
        TerminalController.unregisterRevivedRoot(orphan)

        XCTAssertFalse(
            TerminalController.shared.isDescendant(orphan),
            "a reparented process must be rejected while unregistered — this is the #286 failure"
        )

        TerminalController.registerRevivedRoot(orphan)
        defer { TerminalController.unregisterRevivedRoot(orphan) }

        XCTAssertTrue(
            TerminalController.shared.isDescendant(orphan),
            "a pid adopted from escrow must be accepted as an ancestry root"
        )
    }

    func testUnregisteringARevivedRootWithdrawsAuthorization() throws {
        let orphan = try spawnOrphanedProcess()
        TerminalController.registerRevivedRoot(orphan)
        XCTAssertTrue(TerminalController.shared.isDescendant(orphan))

        TerminalController.unregisterRevivedRoot(orphan)

        XCTAssertFalse(
            TerminalController.shared.isDescendant(orphan),
            "authorization must not outlive the session that owned the pid, or a recycled pid stays trusted"
        )
    }

    func testRevivedRootRegistrationRejectsLaunchdAndInvalidPids() {
        // Registering pid 1 would authorize the ancestry root of every process
        // on the machine, which is the whole boundary `cmuxOnly` protects.
        TerminalController.registerRevivedRoot(1)
        TerminalController.registerRevivedRoot(0)
        TerminalController.registerRevivedRoot(-1)

        XCTAssertFalse(TerminalController.isRevivedRoot(1))
        XCTAssertFalse(TerminalController.isRevivedRoot(0))
        XCTAssertFalse(TerminalController.isRevivedRoot(-1))
    }

    func testOwnDescendantsStillPassWithoutAnyRegistration() {
        // The ordinary path must be untouched by the revived-root addition.
        XCTAssertTrue(
            TerminalController.shared.isDescendant(getpid()),
            "this process must still count as inside its own tree"
        )
    }
}
