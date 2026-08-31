import Foundation
import MobileSpikeFraming
import Testing

@Test func returnsLinesAndEOFWithoutRescanning() async throws {
    let framer = BoundedLineFramer()
    var chunks = [Data("first\nsecond".utf8), Data()]

    let first = try await framer.nextLine { _ in chunks.removeFirst() }
    let second = try await framer.nextLine { _ in chunks.removeFirst() }
    let end = try await framer.nextLine { _ in Data() }

    #expect(first == Data("first".utf8))
    #expect(second == Data("second".utf8))
    #expect(end == nil)
}

@Test func rejectsAFrameBeyondTheEightMiBCeiling() async throws {
    let framer = BoundedLineFramer()
    var remaining = BoundedLineFramer.maximumLineByteCount + 1

    await #expect(throws: BoundedLineFramerError.frameTooLarge) {
        _ = try await framer.nextLine { limit in
            let count = min(Int(limit), remaining)
            remaining -= count
            return Data(repeating: 0x61, count: count)
        }
    }
}

@Test func acceptsExactlyEightMiBBeforeTheDelimiter() async throws {
    let framer = BoundedLineFramer()
    var bytes = Data(repeating: 0x61, count: BoundedLineFramer.maximumLineByteCount)
    bytes.append(0x0A)

    let line = try await framer.nextLine { limit in
        let count = min(Int(limit), bytes.count)
        let chunk = Data(bytes.prefix(count))
        bytes.removeFirst(count)
        return chunk
    }

    #expect(line?.count == BoundedLineFramer.maximumLineByteCount)
}
