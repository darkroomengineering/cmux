import Foundation
import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
final class PortScannerBurstLifecycleTests: XCTestCase {
    func testUnregisteringFinalPanelCancelsQueuedBurstBeforeReplacementPanelAppears() async {
        let scanner = PortScanner(observesAppVisibility: false)
        let workspaceID = UUID()
        let panelID = UUID()
        let firstPublication = expectation(description: "initial panel scan publishes")
        let staleBurstPublication = expectation(
            description: "cancelled burst does not scan a replacement panel without a kick"
        )
        staleBurstPublication.isInverted = true
        var receivedFirstPublication = false
        scanner.onPortsUpdated = { callbackWorkspaceID, callbackPanelID, _ in
            guard callbackWorkspaceID == workspaceID, callbackPanelID == panelID else { return }
            if receivedFirstPublication {
                staleBurstPublication.fulfill()
            } else {
                receivedFirstPublication = true
                firstPublication.fulfill()
            }
        }
        defer { scanner.onPortsUpdated = nil }

        scanner.registerTTY(workspaceId: workspaceID, panelId: panelID, ttyName: "programa-test-old")
        scanner.kick(workspaceId: workspaceID, panelId: panelID)
        await fulfillment(of: [firstPublication], timeout: 3)

        scanner.unregisterPanel(workspaceId: workspaceID, panelId: panelID)
        scanner.registerTTY(workspaceId: workspaceID, panelId: panelID, ttyName: "programa-test-new")

        await fulfillment(of: [staleBurstPublication], timeout: 2)
    }

    func testUnregisteringOnePanelPreservesBurstForRetainedPanel() async {
        let scanner = PortScanner(observesAppVisibility: false)
        let workspaceID = UUID()
        let removedPanelID = UUID()
        let retainedPanelID = UUID()
        let removedInitialPublication = expectation(description: "removed panel initially publishes")
        let retainedInitialPublication = expectation(description: "retained panel initially publishes")
        let retainedFollowupPublication = expectation(description: "retained panel receives next burst scan")
        let removedFollowupPublication = expectation(description: "removed panel receives no later result")
        removedFollowupPublication.isInverted = true
        var initialPanels: Set<UUID> = []
        var observingFollowup = false
        scanner.onPortsUpdated = { callbackWorkspaceID, callbackPanelID, _ in
            guard callbackWorkspaceID == workspaceID else { return }
            if observingFollowup {
                if callbackPanelID == retainedPanelID {
                    retainedFollowupPublication.fulfill()
                } else if callbackPanelID == removedPanelID {
                    removedFollowupPublication.fulfill()
                }
                return
            }
            guard initialPanels.insert(callbackPanelID).inserted else { return }
            if callbackPanelID == removedPanelID {
                removedInitialPublication.fulfill()
            } else if callbackPanelID == retainedPanelID {
                retainedInitialPublication.fulfill()
            }
        }
        defer { scanner.onPortsUpdated = nil }

        scanner.registerTTY(
            workspaceId: workspaceID,
            panelId: removedPanelID,
            ttyName: "programa-test-removed"
        )
        scanner.registerTTY(
            workspaceId: workspaceID,
            panelId: retainedPanelID,
            ttyName: "programa-test-retained"
        )
        scanner.kick(workspaceId: workspaceID, panelId: removedPanelID)
        scanner.kick(workspaceId: workspaceID, panelId: retainedPanelID)
        await fulfillment(
            of: [removedInitialPublication, retainedInitialPublication],
            timeout: 3
        )

        observingFollowup = true
        scanner.unregisterPanel(workspaceId: workspaceID, panelId: removedPanelID)

        await fulfillment(
            of: [retainedFollowupPublication, removedFollowupPublication],
            timeout: 2
        )
    }

    func testStalePanelCompletionIsDroppedWhileCurrentAgentResultSurvives() async {
        let scanner = PortScanner(observesAppVisibility: false)
        let workspaceID = UUID()
        let panelID = UUID()
        let agentPublication = expectation(description: "agent result survives panel generation change")
        let stalePanelPublication = expectation(description: "stale panel snapshot is not published")
        stalePanelPublication.isInverted = true
        var receivedAgentPublication = false
        scanner.onPortsUpdated = { callbackWorkspaceID, callbackPanelID, _ in
            guard callbackWorkspaceID == workspaceID, callbackPanelID == panelID else { return }
            stalePanelPublication.fulfill()
        }
        scanner.onAgentPortsUpdated = { callbackWorkspaceID, ports in
            guard callbackWorkspaceID == workspaceID, !receivedAgentPublication else { return }
            receivedAgentPublication = true
            XCTAssertTrue(ports.isEmpty)
            agentPublication.fulfill()
        }
        scanner.agentPIDsProvider = { callbackWorkspaceIDs in
            XCTAssertEqual(callbackWorkspaceIDs, [workspaceID])
            scanner.unregisterPanel(workspaceId: workspaceID, panelId: panelID)
            scanner.registerTTY(
                workspaceId: workspaceID,
                panelId: panelID,
                ttyName: "programa-test-replacement"
            )
            return [:]
        }
        defer {
            scanner.onPortsUpdated = nil
            scanner.onAgentPortsUpdated = nil
            scanner.agentPIDsProvider = nil
        }

        scanner.registerTTY(
            workspaceId: workspaceID,
            panelId: panelID,
            ttyName: "programa-test-snapshot"
        )
        scanner.kick(workspaceId: workspaceID, panelId: panelID)

        await fulfillment(of: [agentPublication, stalePanelPublication], timeout: 2)
    }
}
