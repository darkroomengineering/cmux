import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class AgentOverviewHierarchyTests: XCTestCase {
    func testWorktreeFolderScopeIncludesWorktreesAndNestedHelpers() {
        let folder = UUID()
        let worktree = UUID()
        let helper = UUID()
        let unrelated = UUID()
        let nodes = [
            AgentOverviewHierarchyNode(
                id: folder,
                worktreeParentId: nil,
                agentParentId: nil,
                isWorktreeFolder: true
            ),
            AgentOverviewHierarchyNode(
                id: worktree,
                worktreeParentId: folder,
                agentParentId: nil,
                isWorktreeFolder: false
            ),
            AgentOverviewHierarchyNode(
                id: helper,
                worktreeParentId: nil,
                agentParentId: worktree,
                isWorktreeFolder: false
            ),
            AgentOverviewHierarchyNode(
                id: unrelated,
                worktreeParentId: nil,
                agentParentId: nil,
                isWorktreeFolder: false
            ),
        ]

        XCTAssertEqual(
            AgentOverviewHierarchy.scopedIds(nodes, rootId: folder),
            [folder, worktree, helper]
        )
        XCTAssertEqual(AgentOverviewHierarchy.orderedIds(nodes), [folder, worktree, helper, unrelated])
        XCTAssertEqual(AgentOverviewHierarchy.depth(of: helper, nodes: nodes), 2)
    }

    func testNormalWorkspaceScopeIncludesOnlyItsAgentDescendants() {
        let workspace = UUID()
        let helper = UUID()
        let worktree = UUID()
        let nodes = [
            AgentOverviewHierarchyNode(
                id: workspace,
                worktreeParentId: nil,
                agentParentId: nil,
                isWorktreeFolder: false
            ),
            AgentOverviewHierarchyNode(
                id: helper,
                worktreeParentId: nil,
                agentParentId: workspace,
                isWorktreeFolder: false
            ),
            AgentOverviewHierarchyNode(
                id: worktree,
                worktreeParentId: workspace,
                agentParentId: nil,
                isWorktreeFolder: false
            ),
        ]

        XCTAssertEqual(
            AgentOverviewHierarchy.scopedIds(nodes, rootId: workspace),
            [workspace, helper]
        )
    }
}

final class AgentOverviewPresentationTests: XCTestCase {
    func testTaskStatesUsePlainUserFacingLabels() {
        XCTAssertEqual(AgentOverviewFriendlyState.from(activityState: nil).label, "Idle")
        XCTAssertEqual(AgentOverviewFriendlyState.from(taskState: .working).label, "Working")
        XCTAssertEqual(AgentOverviewFriendlyState.from(taskState: .blocked).label, "Needs input")
        XCTAssertEqual(AgentOverviewFriendlyState.from(taskState: .completed).label, "Done")
        XCTAssertEqual(AgentOverviewFriendlyState.from(taskState: .cancelled).label, "Stopped")
        XCTAssertEqual(AgentOverviewFriendlyState.from(taskState: .failed).label, "Failed")
    }

    func testFolderPresentationKeepsOnlyTheUsefulTail() {
        XCTAssertEqual(
            AgentOverviewFormatting.shortenedFolder("/Users/example/Developer/programa"),
            "…/Developer/programa"
        )
    }
}

final class AgentOverviewOutputGateTests: XCTestCase {
    func testRunsWithParentHelperNeverEnablesOutput() {
        let workspaceId = UUID()
        let helperId = UUID()
        var gate = AgentOverviewOutputGate()
        gate.isWindowVisible = true
        gate.select(
            .helper(
                workspaceId: workspaceId,
                helperId: helperId,
                surfaceId: UUID(),
                hasIndependentOutput: false
            )
        )
        gate.showOutput()

        XCTAssertFalse(gate.isOutputVisible)
        XCTAssertNil(gate.readRequest)
    }

    func testReportedHelperCannotControlItsAssociatedTerminal() {
        let selection = AgentOverviewSelection.helper(
            workspaceId: UUID(),
            helperId: UUID(),
            surfaceId: UUID(),
            hasIndependentOutput: true
        )

        XCTAssertFalse(selection.allowsTerminalControl)
        XCTAssertNotNil(selection.outputSurfaceId)
    }

    func testOutputRequiresVisibilityAndIsAlwaysLimitedToTwoHundredLines() {
        let workspaceId = UUID()
        let panelId = UUID()
        var gate = AgentOverviewOutputGate()
        gate.select(.terminal(workspaceId: workspaceId, panelId: panelId))
        gate.showOutput()

        XCTAssertNil(gate.readRequest)

        gate.isWindowVisible = true
        XCTAssertEqual(
            gate.readRequest,
            AgentOverviewOutputReadRequest(surfaceId: panelId, lineLimit: 200)
        )

        gate.hideOutput()
        XCTAssertNil(gate.readRequest)
    }

    func testSelectionChangeRequiresOutputToBeOpenedAgain() {
        let workspaceId = UUID()
        var gate = AgentOverviewOutputGate()
        gate.isWindowVisible = true
        gate.select(.terminal(workspaceId: workspaceId, panelId: UUID()))
        gate.showOutput()
        XCTAssertNotNil(gate.readRequest)

        gate.select(.workspace(workspaceId))

        XCTAssertFalse(gate.isOutputVisible)
        XCTAssertNil(gate.readRequest)
    }

    func testDisappearedSelectionClearsOutputAndSelection() {
        let selection = AgentOverviewSelection.terminal(workspaceId: UUID(), panelId: UUID())
        var gate = AgentOverviewOutputGate()
        gate.isWindowVisible = true
        gate.select(selection)
        gate.showOutput()

        gate.reconcile(availableSelections: [])

        XCTAssertNil(gate.selection)
        XCTAssertFalse(gate.isOutputVisible)
        XCTAssertNil(gate.readRequest)
    }

    func testOutputRefreshesAtMostOncePerSecond() {
        var gate = AgentOverviewOutputRefreshGate()
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(gate.shouldRead(now: start))
        XCTAssertFalse(gate.shouldRead(now: start.addingTimeInterval(0.999)))
        XCTAssertTrue(gate.shouldRead(now: start.addingTimeInterval(1)))
    }
}
