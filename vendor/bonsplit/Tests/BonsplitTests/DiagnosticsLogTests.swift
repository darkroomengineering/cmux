import XCTest
@testable import Bonsplit

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
}
