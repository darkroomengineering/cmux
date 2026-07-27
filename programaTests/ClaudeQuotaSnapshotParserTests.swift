import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// `~/.claude/tmp/rate-limits.json` is written by an external tool (cc-settings) that we do
/// not control, so the parser has to be total: malformed input yields `nil`, never a crash
/// and never a partially-filled snapshot.
///
/// The payload also mixes time units in a single object -- `resets_at` is epoch SECONDS
/// (as a string) while `updated_at` is epoch MILLISECONDS (as a number). Getting that
/// backwards silently renders reset countdowns that are wrong by a factor of 1000, which is
/// exactly the kind of bug that looks fine in review, so it is pinned here.
final class ClaudeQuotaSnapshotParserTests: XCTestCase {
    /// Verbatim shape of a real file observed on disk.
    private func payload(
        fiveHourPercent: String = "17",
        fiveHourResets: String = "\"1785171600\"",
        sevenDayPercent: String = "3",
        sevenDayResets: String = "\"1785664800\"",
        updatedAt: String = "1785168986314"
    ) -> Data {
        Data("""
        {"five_hour":{"used_percentage":\(fiveHourPercent),"resets_at":\(fiveHourResets)},
         "seven_day":{"used_percentage":\(sevenDayPercent),"resets_at":\(sevenDayResets)},
         "updated_at":\(updatedAt)}
        """.utf8)
    }

    func testParsesRealPayload() throws {
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload()))

        XCTAssertEqual(snapshot.fiveHour.usedPercent, 17)
        XCTAssertEqual(snapshot.sevenDay.usedPercent, 3)
    }

    /// `resets_at` is a string holding epoch SECONDS.
    func testResetsAtIsParsedAsEpochSeconds() throws {
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload()))

        XCTAssertEqual(snapshot.fiveHour.resetsAt.timeIntervalSince1970, 1_785_171_600, accuracy: 1)
        XCTAssertEqual(snapshot.sevenDay.resetsAt.timeIntervalSince1970, 1_785_664_800, accuracy: 1)
    }

    /// `updated_at` is a number holding epoch MILLISECONDS -- a different unit from
    /// `resets_at` in the same payload.
    func testUpdatedAtIsParsedAsEpochMilliseconds() throws {
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload()))

        XCTAssertEqual(snapshot.updatedAt.timeIntervalSince1970, 1_785_168_986.314, accuracy: 1)
    }

    /// The three timestamps come from one file; if units were confused, `updated_at` would
    /// land ~55 years past the reset times instead of just before them.
    func testUpdatedAtPrecedesResetTimes() throws {
        let snapshot = try XCTUnwrap(ClaudeQuotaSnapshotParser.parse(data: payload()))

        XCTAssertLessThan(snapshot.updatedAt, snapshot.fiveHour.resetsAt)
        XCTAssertLessThan(snapshot.fiveHour.resetsAt, snapshot.sevenDay.resetsAt)
    }

    func testReturnsNilForMalformedJSON() {
        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: Data("{not json".utf8)))
    }

    func testReturnsNilForEmptyData() {
        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: Data()))
    }

    func testReturnsNilWhenAWindowIsMissing() {
        let data = Data("""
        {"five_hour":{"used_percentage":17,"resets_at":"1785171600"},
         "updated_at":1785168986314}
        """.utf8)

        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: data))
    }

    func testReturnsNilWhenPercentageHasWrongType() {
        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: payload(fiveHourPercent: "\"seventeen\"")))
    }

    func testReturnsNilWhenResetTimestampIsNotNumeric() {
        XCTAssertNil(ClaudeQuotaSnapshotParser.parse(data: payload(fiveHourResets: "\"soon\"")))
    }
}
