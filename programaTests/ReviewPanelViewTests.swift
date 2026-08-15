import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
final class ReviewPanelRowPlannerTests: XCTestCase {
    func testRepeatedIdenticalInputReusesRowsWithoutRebuilding() {
        let planner = ReviewPanelRowPlanner()
        let panelID = UUID()
        let files = [makeFile(path: "Sources/App.swift", lineText: "first")]

        let first = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: nil,
            files: files
        )
        let second = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: nil,
            files: files
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(planner.rebuildCount, 1, "An unchanged review should reuse its existing row topology")
    }

    func testSnapshotRevisionInvalidatesCacheAndReflectsChangedRows() {
        let planner = ReviewPanelRowPlanner()
        let panelID = UUID()
        let initialFiles = [makeFile(path: "Sources/App.swift", lineText: "before")]
        let changedFiles = [makeFile(path: "Sources/App.swift", lineText: "after")]

        let initialRows = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: nil,
            files: initialFiles
        )
        let changedRows = planner.rows(
            panelID: panelID,
            filesRevision: 2,
            collapsedFilePaths: [],
            composer: nil,
            files: changedFiles
        )

        XCTAssertEqual(lineTexts(in: initialRows), ["before"])
        XCTAssertEqual(lineTexts(in: changedRows), ["after"])
        XCTAssertEqual(planner.rebuildCount, 2, "A new snapshot revision must invalidate cached review rows")
    }

    func testCollapseHidesDiffAndComposerRowsAndExpandRestoresThem() {
        let planner = ReviewPanelRowPlanner()
        let panelID = UUID()
        let path = "Sources/App.swift"
        let files = [makeFile(path: path, lineText: "changed", newLineNumber: 12)]
        let composer = makeComposer(path: path, endLine: 12)

        let expanded = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: composer,
            files: files
        )
        let collapsed = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [path],
            composer: composer,
            files: files
        )
        let restored = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: composer,
            files: files
        )

        XCTAssertEqual(rowKinds(in: expanded), ["file", "hunk", "line", "composer", "spacing"])
        XCTAssertEqual(rowKinds(in: collapsed), ["file", "spacing"])
        XCTAssertEqual(restored.map(\.id), expanded.map(\.id), "Expanding should restore the same stable row identities")
    }

    func testComposerPlacementFollowsAnchorWhileTextAndRangeStartReuseTopology() {
        let planner = ReviewPanelRowPlanner()
        let panelID = UUID()
        let path = "Sources/App.swift"
        let file = ReviewFileDiff(
            oldPath: path,
            newPath: path,
            status: .modified,
            hunks: [
                ReviewHunk(
                    header: "@@ -9,2 +9,2 @@",
                    lines: [
                        ReviewDiffLine(kind: .context, oldLineNumber: 9, newLineNumber: 9, text: "before"),
                        ReviewDiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 10, text: "target"),
                    ]
                )
            ],
            notDiffableReason: nil
        )

        let initial = makeComposer(path: path, anchorLine: 10, startLine: 10, endLine: 10, text: "draft")
        let initialRows = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: initial,
            files: [file]
        )
        let edited = makeComposer(path: path, anchorLine: 10, startLine: 9, endLine: 10, text: "edited draft")
        let editedRows = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: edited,
            files: [file]
        )

        XCTAssertEqual(rowKinds(in: initialRows), ["file", "hunk", "line", "line", "composer", "spacing"])
        XCTAssertEqual(initialRows.map(\.id), editedRows.map(\.id))
        XCTAssertEqual(planner.rebuildCount, 1, "Composer text and range-start edits should not rebuild row topology")
    }

    func testDuplicateFilePathsProduceDistinctStableRowIDs() {
        let planner = ReviewPanelRowPlanner()
        let panelID = UUID()
        let duplicateFiles = [
            makeFile(path: "Sources/App.swift", lineText: "first"),
            makeFile(path: "Sources/App.swift", lineText: "second"),
        ]

        let firstRevision = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: nil,
            files: duplicateFiles
        )
        let secondRevision = planner.rows(
            panelID: panelID,
            filesRevision: 2,
            collapsedFilePaths: [],
            composer: nil,
            files: duplicateFiles
        )
        let firstIDs = firstRevision.map(\.id)

        XCTAssertEqual(Set(firstIDs).count, firstIDs.count, "Duplicate paths must not collide in SwiftUI row identity")
        XCTAssertEqual(secondRevision.map(\.id), firstIDs, "Snapshot refreshes should preserve row identity for unchanged files")
    }

    func testApplyingSnapshotsAdvancesFilesRevision() {
        let panel = ReviewPanel(
            workspaceId: UUID(),
            sourceSurfaceId: UUID(),
            directory: "/tmp",
            mode: .uncommitted,
            baseBranch: "origin/main"
        )
        let firstFile = makeFile(path: "Sources/App.swift", lineText: "first")
        let secondFile = makeFile(path: "Sources/App.swift", lineText: "second")

        panel.apply(snapshot: ReviewDiffSnapshot(files: [firstFile], generatedAt: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(panel.filesRevision, 1)
        XCTAssertEqual(panel.files, [firstFile])

        panel.apply(snapshot: ReviewDiffSnapshot(files: [secondFile], generatedAt: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(panel.filesRevision, 2)
        XCTAssertEqual(panel.files, [secondFile])
    }

    private func makeFile(
        path: String,
        lineText: String,
        newLineNumber: Int = 1
    ) -> ReviewFileDiff {
        ReviewFileDiff(
            oldPath: path,
            newPath: path,
            status: .modified,
            hunks: [
                ReviewHunk(
                    header: "@@ -1 +1 @@",
                    lines: [
                        ReviewDiffLine(
                            kind: .addition,
                            oldLineNumber: nil,
                            newLineNumber: newLineNumber,
                            text: lineText
                        )
                    ]
                )
            ],
            notDiffableReason: nil
        )
    }

    private func makeComposer(
        path: String,
        anchorLine: Int = 1,
        startLine: Int = 1,
        endLine: Int,
        text: String = "comment"
    ) -> ReviewPanelComposerTopology {
        ReviewPanelComposerTopology(
            filePath: path,
            anchorLine: anchorLine,
            startLine: startLine,
            endLine: endLine,
            text: text
        )
    }

    private func lineTexts(in rows: [ReviewPanelRow]) -> [String] {
        rows.compactMap { row in
            guard case .line(_, _, _, let annotated, _) = row else { return nil }
            return annotated.line.text
        }
    }

    private func rowKinds(in rows: [ReviewPanelRow]) -> [String] {
        rows.map { row in
            switch row {
            case .fileHeader: return "file"
            case .notDiffable: return "notDiffable"
            case .hunkHeader: return "hunk"
            case .line: return "line"
            case .composer: return "composer"
            case .fileSpacing: return "spacing"
            }
        }
    }
}
