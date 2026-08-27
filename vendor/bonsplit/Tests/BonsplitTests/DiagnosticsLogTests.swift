import XCTest
@testable import Bonsplit

private final class DiagnosticsFileHandleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var openedHandles: [FileHandle] = []

    func open(_ url: URL) -> FileHandle? {
        lock.lock()
        defer { lock.unlock() }

        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else { return nil }
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return nil }
        openedHandles.append(handle)
        return handle
    }

    var handles: [FileHandle] {
        lock.lock()
        defer { lock.unlock() }
        return openedHandles
    }
}

private final class DiagnosticsRotationFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptedRotations = 0

    func fail(source: URL, destination: URL) -> Bool {
        lock.lock()
        attemptedRotations += 1
        lock.unlock()
        return false
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attemptedRotations
    }
}

final class DiagnosticsLogTests: XCTestCase {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsLogTests-\(UUID().uuidString).log")
    }

    private func waitForQueue(_ log: DiagnosticsLog) {
        log.flush()
    }

    func testWritesLandInFileAtPath() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = DiagnosticsLog(fileURL: url)

        for i in 0..<5 {
            log.log("test.category", "line \(i)")
        }
        waitForQueue(log)

        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[0].contains("test.category"))
        XCTAssertTrue(lines[0].contains("line 0"))
        XCTAssertTrue(lines[4].contains("line 4"))
    }

    func testExceedingCapRotatesToDotOneFile() {
        let url = tempFileURL()
        let rotatedURL = url.deletingPathExtension().appendingPathExtension("log.1")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: rotatedURL)
        }
        let log = DiagnosticsLog(fileURL: url)

        // Each line is padded to push well past the 2 MB cap in a small number of writes.
        let padding = String(repeating: "x", count: 64 * 1024)
        for i in 0..<40 {
            log.log("test.category", "\(padding) \(i)")
        }
        waitForQueue(log)

        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path), "expected rotated file to exist")

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let currentSize = (attrs?[.size] as? UInt64) ?? 0
        XCTAssertLessThan(currentSize, 2 * 1024 * 1024, "current log file should be smaller than the cap after rotation")
    }

    func testQueuedRecordsReuseOneOpenFileHandleBeforeRotation() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = DiagnosticsFileHandleProbe()

        // Package-internal test seam: production owns handle reuse and accepts
        // only an opener for observing real file-handle lifetimes.
        let log = DiagnosticsLog(fileURL: url, fileHandleOpener: { probe.open($0) })
        for i in 0..<20 {
            log.log("test.reuse", "record-\(i)")
        }
        waitForQueue(log)

        XCTAssertEqual(
            probe.handles.count,
            1,
            "Queued records below the rotation cap must reuse one open file handle instead of reopening the file per record"
        )
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertEqual(contents.split(separator: "\n").count, 20)
    }

    func testRotationClosesAndReplacesHandleWithoutLosingRecords() throws {
        let url = tempFileURL()
        let rotatedURL = url.deletingPathExtension().appendingPathExtension("log.1")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: rotatedURL)
        }
        let probe = DiagnosticsFileHandleProbe()
        let log = DiagnosticsLog(fileURL: url, fileHandleOpener: { probe.open($0) })

        // Three records fit below 2 MB. The fourth crosses the cap exactly once,
        // so it must land through a replacement handle in the new current file.
        let padding = String(repeating: "x", count: 600 * 1024)
        for i in 0..<4 {
            log.log("test.rotation", "record-\(i) \(padding)")
        }
        waitForQueue(log)

        let handles = probe.handles
        guard handles.count == 2 else {
            XCTFail("Rotation must replace the active handle exactly once; opened \(handles.count) handles")
            return
        }
        XCTAssertThrowsError(
            try handles[0].seekToEnd(),
            "The pre-rotation handle must be closed before its file is moved"
        )
        XCTAssertNoThrow(
            try handles[1].seekToEnd(),
            "The post-rotation current file must remain attached to the replacement handle"
        )

        let current = try String(contentsOf: url, encoding: .utf8)
        let rotated = try String(contentsOf: rotatedURL, encoding: .utf8)
        let combined = current + rotated
        for i in 0..<4 {
            XCTAssertEqual(
                combined.components(separatedBy: "record-\(i)").count - 1,
                1,
                "Rotation must preserve record-\(i) exactly once across the current and .1 files"
            )
        }
        XCTAssertTrue(current.contains("record-3"), "The record that crosses the cap must be written to the new current file")
        XCTAssertFalse(rotated.contains("record-3"), "The post-rotation record must not be appended to the rotated file")
    }

    func testFailedRotationPreservesBackupAndKeepsCurrentHandleUsable() throws {
        let url = tempFileURL()
        let rotatedURL = url.deletingPathExtension().appendingPathExtension("log.1")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: rotatedURL)
        }

        let existingBackup = Data("existing-backup-must-survive".utf8)
        try existingBackup.write(to: rotatedURL)
        try Data(repeating: 0x78, count: 2 * 1024 * 1024 - 512).write(to: url)

        let handles = DiagnosticsFileHandleProbe()
        let rotation = DiagnosticsRotationFailureProbe()
        let log = DiagnosticsLog(
            fileURL: url,
            fileHandleOpener: { handles.open($0) },
            fileRotator: { rotation.fail(source: $0, destination: $1) }
        )

        log.log("test.rotation-failure", "before-failure")
        log.log("test.rotation-failure", "cross-cap \(String(repeating: "y", count: 1024))")
        for i in 0..<10 {
            log.log("test.rotation-failure", "after-failure-\(i)")
        }
        waitForQueue(log)

        XCTAssertEqual(try Data(contentsOf: rotatedURL), existingBackup, "A failed rotation must not destroy the last readable backup")
        XCTAssertEqual(rotation.attemptCount, 1, "A failed rotation must not close and reopen the current file for every later record")

        let openedHandles = handles.handles
        guard openedHandles.count == 2 else {
            XCTFail("A failed rotation must reopen the current log once; opened \(openedHandles.count) handles")
            return
        }
        XCTAssertThrowsError(try openedHandles[0].seekToEnd(), "The handle closed for rotation must stay closed")
        XCTAssertNoThrow(try openedHandles[1].seekToEnd(), "The current log must remain writable through its replacement handle")

        let current = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(current.contains("before-failure"))
        XCTAssertTrue(current.contains("cross-cap"))
        XCTAssertTrue(current.contains("after-failure-9"), "Records after a failed rotation must remain visible at the configured path")
    }

    func testDeletedLogDirectoryIsRecreatedWithinBoundedRecordInterval() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsLogTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("diagnostics.log")
        defer { try? FileManager.default.removeItem(at: directory) }

        let probe = DiagnosticsFileHandleProbe()
        let log = DiagnosticsLog(fileURL: url, fileHandleOpener: { probe.open($0) })
        log.log("test.directory", "before-directory-removal")
        waitForQueue(log)
        XCTAssertEqual(probe.handles.count, 1, "The precondition requires one active handle before external deletion")

        try FileManager.default.removeItem(at: directory)
        let validationBound = DiagnosticsLog.pathValidationRecordInterval
        XCTAssertGreaterThan(validationBound, 0, "Path validation must use a positive bounded record interval")
        if validationBound > 1 {
            for i in 1..<validationBound {
                log.log("test.directory", "after-removal-\(i)")
            }
        }
        log.log("test.directory", "visible-after-recreate")
        waitForQueue(log)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "The logger must recreate an externally removed log directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The logger must restore the configured current log path")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("visible-after-recreate"), "A marker after bounded path validation must be readable from the configured path")

        let openedHandles = probe.handles
        guard openedHandles.count == 2 else {
            XCTFail("External directory removal must replace the orphaned handle once; opened \(openedHandles.count) handles")
            return
        }
        XCTAssertThrowsError(try openedHandles[0].seekToEnd(), "The handle orphaned by directory removal must be closed")
        XCTAssertNoThrow(try openedHandles[1].seekToEnd(), "The recreated current log must retain its replacement handle")
    }
}
