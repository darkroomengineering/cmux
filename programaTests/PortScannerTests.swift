import Foundation
import XCTest
import os

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
final class PortScannerBurstLifecycleTests: XCTestCase {
    func testLargeAgentPIDScanBatchesAndUnionsEveryChunkResult() async {
        let workspaceID = UUID()
        let inputPIDs = Array(1_000_000..<1_020_000)
        let expectedPorts = Array(10_000..<30_000)
        let recordedChunks = OSAllocatedUnfairLock(initialState: [[Int]]())
        let scanner = PortScanner(
            observesAppVisibility: false,
            lsofChunkOverride: { pidsCSV in
                let pids = pidsCSV.split(separator: ",").compactMap { Int($0) }
                recordedChunks.withLock { $0.append(pids) }
                return Dictionary(uniqueKeysWithValues: pids.map { pid in
                    (pid, Set([pid - 990_000]))
                })
            }
        )
        let publication = expectation(description: "all batched lsof results publish together")
        var publishedPorts: [Int]?
        scanner.onAgentPortsUpdated = { callbackWorkspaceID, ports in
            guard callbackWorkspaceID == workspaceID, publishedPorts == nil else { return }
            publishedPorts = ports
            publication.fulfill()
        }
        defer { scanner.onAgentPortsUpdated = nil }

        scanner.refreshAgentPorts(workspaceId: workspaceID, agentPIDs: Set(inputPIDs))
        await fulfillment(of: [publication], timeout: 10)

        let chunks = recordedChunks.withLock { $0 }
        XCTAssertGreaterThan(
            chunks.count,
            1,
            "a single lsof argv cannot safely carry a 20,000-process agent tree"
        )
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 256)
            let csvBytes = chunk.map(String.init).joined(separator: ",").utf8.count
            XCTAssertLessThanOrEqual(csvBytes + 256, 32 * 1024)
        }
        XCTAssertEqual(chunks.flatMap { $0 }, inputPIDs)
        XCTAssertEqual(publishedPorts, expectedPorts)
    }

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
