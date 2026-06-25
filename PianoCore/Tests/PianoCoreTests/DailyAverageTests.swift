//
//  DailyAverageTests.swift — the priority suite. Pure, no filesystem.
//
//  Covers the spec's required edge cases: zero/one entry, non-adjacent same-day
//  collapse, the rolling 90-day window edge, migration exclusion, and out-of-window.
//

import XCTest
@testable import PianoCore

final class DailyAverageTests: XCTestCase {

    // Deterministic calendar: gregorian, fixed UTC, so "distinct days" and the rolling
    // window never depend on the machine's locale/timezone or on DST.
    private let utc = TimeZone(identifier: "UTC")!
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(timeZone: utc, year: y, month: m, day: d, hour: h))!
    }
    private func entry(_ student: UUID, _ amount: Int, _ at: Date,
                       monster: UUID = UUID(), origin: EntryOrigin = .live, seq: Int = 0) -> CombatLogEntry {
        CombatLogEntry(sequence: seq, studentID: student, monsterRecordID: monster,
                       amount: amount, timestamp: at, origin: origin)
    }

    func testZeroEntriesIsZeroNotNaN() {
        let s = UUID()
        let avg = PracticeMath.dailyAverage(forStudent: s, entries: [],
                                            now: date(2026, 3, 13), calendar: cal)
        XCTAssertEqual(avg, 0)
        XCTAssertFalse(avg.isNaN)
        XCTAssertFalse(avg.isInfinite)
    }

    func testSingleEntryIsAmountOverOneDay() {
        let s = UUID()
        let avg = PracticeMath.dailyAverage(forStudent: s,
                                            entries: [entry(s, 17, date(2026, 3, 1))],
                                            now: date(2026, 3, 13), calendar: cal)
        XCTAssertEqual(avg, 17, accuracy: 0.0001)
    }

    /// Spec example: 15 and 6 on 1/5, plus 25 on 3/12 = 46 over 2 distinct days = 23.
    /// (Jan 5 → Mar 13 is 67 days, well within the 90-day window.)
    func testNonAdjacentSameDayCollapsesToOneDay() {
        let s = UUID()
        let entries = [
            entry(s, 15, date(2026, 1, 5, 9)),
            entry(s, 6,  date(2026, 1, 5, 18)),   // same calendar day as above
            entry(s, 25, date(2026, 3, 12)),
        ]
        let avg = PracticeMath.dailyAverage(forStudent: s, entries: entries,
                                            now: date(2026, 3, 13), calendar: cal)
        XCTAssertEqual(avg, 23, accuracy: 0.0001)
    }

    /// The rolling 90-day boundary: an entry exactly at the cutoff is counted, one a
    /// moment more recent is counted, one a moment older is excluded.
    func testNinetyDayRollingWindowEdgeIsInclusiveAndExcludesOlder() {
        let s = UUID()
        let now = date(2026, 6, 25, 14)
        let cutoff = cal.date(byAdding: .day, value: -90, to: now)!         // exactly 90 days back
        let justInside = cal.date(byAdding: .second, value: 1, to: cutoff)!  // 1s more recent → in
        let justOutside = cal.date(byAdding: .second, value: -1, to: cutoff)! // 1s older → out

        // Each boundary case in isolation:
        XCTAssertEqual(PracticeMath.dailyAverage(forStudent: s, entries: [entry(s, 4, cutoff)],
                                                 now: now, calendar: cal),
                       4, accuracy: 0.0001, "entry exactly at the 90-day edge must count")
        XCTAssertEqual(PracticeMath.dailyAverage(forStudent: s, entries: [entry(s, 5, justInside)],
                                                 now: now, calendar: cal),
                       5, accuracy: 0.0001, "entry just inside the window must count")
        XCTAssertEqual(PracticeMath.dailyAverage(forStudent: s, entries: [entry(s, 1000, justOutside)],
                                                 now: now, calendar: cal),
                       0, accuracy: 0.0001, "entry just outside the window must be excluded")

        // Combined: cutoff + justInside share one calendar day (1s apart) → 9 over 1 day;
        // justOutside excluded. If the cutoff were wrongly exclusive this would be 5;
        // if justOutside leaked in it would be 1009.
        let avg = PracticeMath.dailyAverage(forStudent: s,
                                            entries: [entry(s, 4, cutoff),
                                                      entry(s, 5, justInside),
                                                      entry(s, 1000, justOutside)],
                                            now: now, calendar: cal)
        XCTAssertEqual(avg, 9, accuracy: 0.0001)
    }

    func testMigrationEntriesExcludedFromBothSumAndDayCount() {
        let s = UUID()
        let entries = [
            entry(s, 100, date(2026, 3, 1), origin: .migration), // ignored entirely
            entry(s, 20,  date(2026, 3, 2), origin: .live),
        ]
        let avg = PracticeMath.dailyAverage(forStudent: s, entries: entries,
                                            now: date(2026, 3, 13), calendar: cal)
        XCTAssertEqual(avg, 20, accuracy: 0.0001) // 20 over 1 day, migration row invisible
    }

    func testOutOfWindowEntriesExcluded() {
        let s = UUID()
        let entries = [
            entry(s, 999, date(2025, 1, 1)), // far older than 90 days → excluded
            entry(s, 8,   date(2026, 3, 10)),
        ]
        let avg = PracticeMath.dailyAverage(forStudent: s, entries: entries,
                                            now: date(2026, 3, 13), calendar: cal)
        XCTAssertEqual(avg, 8, accuracy: 0.0001)
    }

    func testOnlyTheNamedStudentsEntriesCount() {
        let s = UUID(); let other = UUID()
        let entries = [
            entry(s, 10, date(2026, 3, 1)),
            entry(other, 9999, date(2026, 3, 1)),
        ]
        let avg = PracticeMath.dailyAverage(forStudent: s, entries: entries,
                                            now: date(2026, 3, 13), calendar: cal)
        XCTAssertEqual(avg, 10, accuracy: 0.0001)
    }
}
