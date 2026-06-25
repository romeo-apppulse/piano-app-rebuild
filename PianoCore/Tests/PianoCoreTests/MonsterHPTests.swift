//
//  MonsterHPTests.swift — the HP formula and effective-HP edge cases.
//

import XCTest
@testable import PianoCore

final class MonsterHPTests: XCTestCase {

    private func record(averages: [Double] = [],
                        killTargetWeeks: Int = 3,
                        backdoorHPDelta: Int = 0,
                        legacyFixedHP: Int? = nil) -> MonsterRecord {
        MonsterRecord(
            templateID: UUID(),
            kind: .regular,
            teamID: UUID(),
            spawnedAt: Date(timeIntervalSince1970: 0),
            spawnSequence: 0,
            spawnAverages: averages.map { StudentAverage(studentID: UUID(), average: $0) },
            killTargetWeeks: killTargetWeeks,
            backdoorHPDelta: backdoorHPDelta,
            legacyFixedHP: legacyFixedHP
        )
    }

    /// Spec example: 20.5 + 13 + 8.25 = 41.75 × 3 = 125.25 → round up → 126.
    func testBaseHPWorkedExample() {
        XCTAssertEqual(MonsterMath.baseHP(dailyAverages: [20.5, 13, 8.25], killTargetWeeks: 3), 126)
    }

    func testBaseHPRoundsUpExactlyOnceAtTheEnd() {
        // 41.75 × 1 = 41.75 → 42. (Averages are NOT rounded individually first.)
        XCTAssertEqual(MonsterMath.baseHP(dailyAverages: [20.5, 13, 8.25], killTargetWeeks: 1), 42)
    }

    func testBaseHPEmptyTeamIsZeroBeforeFloor() {
        XCTAssertEqual(MonsterMath.baseHP(dailyAverages: [], killTargetWeeks: 3), 0)
    }

    func testEffectiveHPFloorsSoMonsterNeverSpawnsDead() {
        let r = record(averages: [], killTargetWeeks: 3) // base 0
        XCTAssertEqual(MonsterMath.effectiveHP(for: r, minimumHP: 1), 1)
    }

    func testEffectiveHPAppliesBackdoorDelta() {
        let r = record(averages: [20.5, 13, 8.25], killTargetWeeks: 3, backdoorHPDelta: 10) // 126 + 10
        XCTAssertEqual(MonsterMath.effectiveHP(for: r, minimumHP: 1), 136)
    }

    func testKillTargetChangeRecomputesFromSameFrozenAverages() {
        let r3 = record(averages: [20.5, 13, 8.25], killTargetWeeks: 3) // 126
        let r6 = record(averages: [20.5, 13, 8.25], killTargetWeeks: 6) // 41.75×6 = 250.5 → 251
        XCTAssertEqual(MonsterMath.effectiveHP(for: r3, minimumHP: 1), 126)
        XCTAssertEqual(MonsterMath.effectiveHP(for: r6, minimumHP: 1), 251)
    }

    func testLegacyFixedHPShortCircuitsFormulaButHonorsDeltaAndFloor() {
        // Migrated monster: HP pinned to the old app's value, ignoring averages.
        let pinned = record(averages: [100, 100], killTargetWeeks: 3, backdoorHPDelta: -5, legacyFixedHP: 80)
        XCTAssertEqual(MonsterMath.effectiveHP(for: pinned, minimumHP: 1), 75) // 80 - 5

        let pinnedBelowFloor = record(averages: [], killTargetWeeks: 3, backdoorHPDelta: -100, legacyFixedHP: 80)
        XCTAssertEqual(MonsterMath.effectiveHP(for: pinnedBelowFloor, minimumHP: 1), 1) // floored
    }
}
