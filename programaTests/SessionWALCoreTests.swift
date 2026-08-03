import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class SessionWALCoreTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-session-wal-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testDoubleBufferAppendDrainAndOverflowPreserveNewestBytes() {
        let ring = SessionWALRingBuffer(capacity: 8)

        append(Array("abc".utf8), to: ring)
        XCTAssertEqual(ring.drain(), Array("abc".utf8))
        XCTAssertNil(ring.drain())

        append(Array("0123456789".utf8), to: ring)
        XCTAssertEqual(ring.drain(), Array("23456789".utf8))
    }

    func testAppendRotatesAndPersistsGenerationBeforeFrameCapture() throws {
        let paths = makePaths()
        try seedMeta(at: paths)

        let initial = try SessionWALCore.append(
            Data("abcd".utf8),
            to: paths,
            walCapBytes: 6,
            synchronize: true
        )
        XCTAssertFalse(initial.didRotate)
        XCTAssertEqual(initial.currentWalSize, 4)
        XCTAssertEqual(initial.walGeneration, 0)

        let rotated = try SessionWALCore.append(
            Data("efg".utf8),
            to: paths,
            walCapBytes: 6,
            synchronize: true
        )
        XCTAssertTrue(rotated.didRotate)
        XCTAssertEqual(rotated.currentWalSize, 3)
        XCTAssertEqual(rotated.walGeneration, 1)
        XCTAssertEqual(try Data(contentsOf: paths.walRotatedURL), Data("abcd".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.walURL), Data("efg".utf8))
        XCTAssertEqual(SessionWALCore.readMeta(at: paths)?.walGeneration, 1)

        try writeFrame("FRAME", offset: rotated.currentWalSize, generation: 1, at: paths)
        _ = try SessionWALCore.append(
            Data("hi".utf8),
            to: paths,
            walCapBytes: 6,
            synchronize: true
        )
        XCTAssertEqual(
            SessionWALCore.readFrameAndDelta(at: paths, walCapBytes: 6),
            "FRAMEhi",
            "A frame captured after rotation must replay from the new WAL generation and offset"
        )
    }

    func testRotationAfterFrameInvalidatesOffsetEvenWhenNewWALRegrowsPastIt() throws {
        let paths = makePaths()
        try seedMeta(at: paths)

        let beforeFrame = try SessionWALCore.append(
            Data("old".utf8),
            to: paths,
            walCapBytes: 6,
            synchronize: true
        )
        try writeFrame(
            "OLD-FRAME",
            offset: beforeFrame.currentWalSize,
            generation: beforeFrame.walGeneration,
            at: paths
        )

        let afterFrame = try SessionWALCore.append(
            Data("new!".utf8),
            to: paths,
            walCapBytes: 6,
            synchronize: true
        )
        XCTAssertTrue(afterFrame.didRotate)
        XCTAssertEqual(afterFrame.walGeneration, 1)
        XCTAssertGreaterThanOrEqual(
            afterFrame.currentWalSize,
            beforeFrame.currentWalSize,
            "The replacement WAL deliberately regrows beyond the stale frame offset"
        )
        XCTAssertNil(
            SessionWALCore.readFrameAndDelta(at: paths, walCapBytes: 6),
            "Generation mismatch must reject a numerically valid offset from the wrong WAL"
        )
    }

    func testOffsetAndDeltaReplayUsesOnlyBytesWrittenAfterFrame() throws {
        let paths = makePaths()
        try seedMeta(at: paths)

        let beforeFrame = try SessionWALCore.append(
            Data("prompt> ".utf8),
            to: paths,
            walCapBytes: 64,
            synchronize: true
        )
        try writeFrame(
            "VISIBLE-SCREEN",
            offset: beforeFrame.currentWalSize,
            generation: beforeFrame.walGeneration,
            at: paths
        )
        _ = try SessionWALCore.append(
            Data("command output".utf8),
            to: paths,
            walCapBytes: 64,
            synchronize: true
        )

        XCTAssertEqual(
            SessionWALCore.readFrameAndDelta(at: paths, walCapBytes: 64),
            "VISIBLE-SCREENcommand output"
        )
    }

    /// Reproduces the corrupted-restore symptom (transcript fragments at wrong
    /// columns, mid-word garbage like "m0de"): the WAL delta returned by
    /// `readFrameAndDelta` is a raw byte slice, so a `walOffset` that lands
    /// mid-escape-sequence or mid-UTF-8-scalar leaks the orphaned tail bytes
    /// into the replayed text instead of being trimmed.
    func testFrameAndDeltaTrimsLeadingPartialEscapeAndUTF8() throws {
        // Scenario 1: walOffset lands inside a CSI parameter run. The full WAL
        // is a single (otherwise complete) SGR color-set sequence followed by
        // plain content; offset 3 sits right after "ESC[3", so the delta's
        // first bytes are the orphaned tail "8;5;196m" of that sequence.
        let csiPaths = makePaths()
        try seedMeta(at: csiPaths)
        let walText = "\u{001B}[38;5;196mVISIBLE"
        try Data(walText.utf8).write(to: csiPaths.walURL)
        try writeFrame("HELLO", offset: 3, generation: 0, at: csiPaths)

        let csiReplayed = SessionWALCore.readFrameAndDelta(at: csiPaths, walCapBytes: 4096)
        XCTAssertEqual(
            csiReplayed,
            "HELLOVISIBLE",
            "A delta beginning mid-CSI-sequence must drop the orphaned parameter/final bytes, not leak them as literal text"
        )
        XCTAssertFalse(
            (csiReplayed ?? "").contains("8;5;196m"),
            "The orphaned CSI parameter tail must never appear as literal replayed text"
        )

        // Scenario 2: walOffset lands inside a multi-byte UTF-8 scalar. "é" is
        // encoded as the two bytes 0xC3 0xA9; offset 2 sits between them, so
        // the delta's first byte is a lone UTF-8 continuation byte.
        let utf8Paths = makePaths()
        try seedMeta(at: utf8Paths)
        let utf8WalText = "x\u{00E9}post"
        try Data(utf8WalText.utf8).write(to: utf8Paths.walURL)
        try writeFrame("PRE", offset: 2, generation: 0, at: utf8Paths)

        let utf8Replayed = SessionWALCore.readFrameAndDelta(at: utf8Paths, walCapBytes: 4096)
        XCTAssertEqual(
            utf8Replayed,
            "PREpost",
            "A delta beginning mid-UTF-8-scalar must drop the orphaned continuation byte, not decode it as U+FFFD"
        )
        XCTAssertFalse(
            (utf8Replayed ?? "").contains("\u{FFFD}"),
            "No replacement character should appear at a UTF-8 seam that was safely trimmed"
        )
    }

    private func makePaths() -> SessionWALPaths {
        SessionWALPaths(
            sessionDirectory: temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
    }

    private func seedMeta(at paths: SessionWALPaths, generation: Int = 0) throws {
        let meta = SessionWALMeta(
            sessionId: paths.sessionDirectory.lastPathComponent,
            childPID: nil,
            ptyPath: nil,
            workingDirectory: "/tmp",
            lastHeartbeatAt: Date(timeIntervalSince1970: 1_700_000_000),
            walGeneration: generation,
            escrowed: nil,
            escrowSocketPath: nil,
            escrowToken: nil
        )
        try SessionWALCore.persistMeta(meta, to: paths)
    }

    private func writeFrame(
        _ text: String,
        offset: Int64,
        generation: Int,
        at paths: SessionWALPaths
    ) throws {
        try SessionWALCore.writeFrame(
            text,
            meta: SessionFrameMeta(
                sessionId: paths.sessionDirectory.lastPathComponent,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_001),
                walOffset: offset,
                walGeneration: generation
            ),
            to: paths
        )
    }

    private func append(_ bytes: [UInt8], to ring: SessionWALRingBuffer) {
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            ring.append(baseAddress, buffer.count)
        }
    }
}
