//
//  ExtraBoardsAndExtraPointsTests.swift — the client's extra leaderboards (highest
//  single hit, weekly damage, weekly team damage) and the "Extra Points" damage type
//  (real damage that counts on the damage boards but NOT toward practice averages).
//

import XCTest
@testable import PianoCore

final class ExtraBoardsAndExtraPointsTests: XCTestCase {

    private func t(_ s: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }

    // MARK: - Highest single hit

    func testHighestSingleHitRanksByBiggestHitExcludingSeeds() {
        let sA = UUID(); let sB = UUID(); let mID = UUID()
        let entries = [
            CombatLogEntry(sequence: 0, studentID: sA, monsterRecordID: mID, amount: 5, timestamp: t(1_000_000)),
            CombatLogEntry(sequence: 1, studentID: sA, monsterRecordID: mID, amount: 12, timestamp: t(1_000_000)),
            // A day-one seed is a lump baseline, not a "hit" — it must be ignored here.
            CombatLogEntry(sequence: 2, studentID: sB, monsterRecordID: mID, amount: 20, timestamp: t(1_000_000), origin: .migration),
            CombatLogEntry(sequence: 3, studentID: sB, monsterRecordID: mID, amount: 8, timestamp: t(1_000_000)),
        ]
        let state = AppState(
            students: [Student(id: sA, name: "A", createdAt: t(0)),
                       Student(id: sB, name: "B", createdAt: t(0))],
            combatLog: CombatLog(entries: entries, nextSequence: 4)
        )
        let board = Leaderboards.highestSingleHit(state: state)
        XCTAssertEqual(board.map { $0.id }, [sA, sB])              // 12 > 8 (seed 20 ignored)
        XCTAssertEqual(board.first { $0.id == sA }?.totalDamage, 12)
        XCTAssertEqual(board.first { $0.id == sB }?.totalDamage, 8)
    }

    // MARK: - Weekly + team weekly

    func testWeeklyDamageWindowsOldEntriesOutAndTeamWeeklySums() {
        let team = UUID(); let sA = UUID(); let sB = UUID(); let mID = UUID()
        let now = t(1_000_000)
        let inWindow = t(1_000_000 - 3_600)          // 1h ago
        let tooOld = t(1_000_000 - 8 * 86_400)       // 8 days ago → outside the 7-day window
        let entries = [
            CombatLogEntry(sequence: 0, studentID: sA, monsterRecordID: mID, amount: 10, timestamp: inWindow),
            CombatLogEntry(sequence: 1, studentID: sA, monsterRecordID: mID, amount: 100, timestamp: tooOld),
            CombatLogEntry(sequence: 2, studentID: sB, monsterRecordID: mID, amount: 7, timestamp: inWindow),
        ]
        let state = AppState(
            students: [Student(id: sA, name: "A", teamID: team, createdAt: t(0)),
                       Student(id: sB, name: "B", teamID: team, createdAt: t(0))],
            teams: [Team(id: team, name: "Reds")],
            combatLog: CombatLog(entries: entries, nextSequence: 3)
        )
        let weekly = Leaderboards.weeklyDamage(state: state, now: now)
        XCTAssertEqual(weekly.first { $0.id == sA }?.totalDamage, 10)   // the 100 is too old
        XCTAssertEqual(weekly.first { $0.id == sB }?.totalDamage, 7)

        let teamBoard = Leaderboards.teamWeekly(state: state, now: now)
        XCTAssertEqual(teamBoard.first { $0.id == team }?.totalDamage, 17)   // 10 + 7
        XCTAssertEqual(teamBoard.first { $0.id == team }?.displayName, "Reds")
    }

    // MARK: - Extra Points

    func testExtraPointsCountForHpAndDamageBoardsButNotAverages() {
        let team = UUID(); let s = UUID(); let mID = UUID(); let tpl = UUID()
        var state = AppState(
            students: [Student(id: s, name: "Eric", teamID: team, createdAt: t(0))],
            teams: [Team(id: team, name: "T")],
            monsterCatalog: [MonsterTemplate(id: tpl, name: "M", kind: .regular)],
            ledger: [MonsterRecord(id: mID, templateID: tpl, kind: .regular, teamID: team,
                                   spawnedAt: t(0), spawnSequence: 0, killTargetWeeks: 3, legacyFixedHP: 100)],
            settings: GameSettings(minimumMonsterHP: 5)
        )
        let day = t(1_000_000)
        _ = try! GameEngine.attack(into: &state, targetRecordID: mID, studentID: s, amount: 30, at: day, origin: .extraPoints).get()
        _ = try! GameEngine.attack(into: &state, targetRecordID: mID, studentID: s, amount: 10, at: day, origin: .live).get()

        // Both hits reduced HP (100 - 30 - 10 = 60).
        XCTAssertEqual(state.remainingHP(of: state.monsterRecord(mID)!), 60)

        // The average counts ONLY the live 10 (one day); the 30 extra points are excluded.
        let cal = state.settings.resolvedCalendar
        XCTAssertEqual(PracticeMath.dailyAverage(forStudent: s, entries: state.combatLog.entries,
                                                 now: t(1_000_100), calendar: cal), 10)

        // But the damage boards see both.
        XCTAssertEqual(Leaderboards.highestSingleHit(state: state).first { $0.id == s }?.totalDamage, 30)
        XCTAssertEqual(Leaderboards.weeklyDamage(state: state, now: t(1_000_100)).first { $0.id == s }?.totalDamage, 40)

        // And the entry is tagged so the log can read "…Extra Points dmg…".
        XCTAssertTrue(state.combatLog.entries.contains { $0.origin == .extraPoints && $0.amount == 30 })
    }

    /// Editing an Extra Points entry keeps it Extra Points (origin preserved on re-apply).
    func testEditingAnExtraPointsEntryKeepsItExtra() {
        let team = UUID(); let s = UUID(); let mID = UUID(); let tpl = UUID()
        var state = AppState(
            students: [Student(id: s, name: "Eric", teamID: team, createdAt: t(0))],
            teams: [Team(id: team, name: "T")],
            monsterCatalog: [MonsterTemplate(id: tpl, name: "M", kind: .regular)],
            ledger: [MonsterRecord(id: mID, templateID: tpl, kind: .regular, teamID: team,
                                   spawnedAt: t(0), spawnSequence: 0, killTargetWeeks: 3, legacyFixedHP: 100)],
            settings: GameSettings(minimumMonsterHP: 5)
        )
        _ = try! GameEngine.attack(into: &state, targetRecordID: mID, studentID: s, amount: 30, at: t(1_000_000), origin: .extraPoints).get()
        _ = try! GameEngine.editMostRecentAttack(into: &state, teamScope: team, newAmount: 15).get()

        XCTAssertEqual(state.combatLog.entries.count, 1)
        XCTAssertEqual(state.combatLog.entries.first?.origin, .extraPoints)
        XCTAssertEqual(state.combatLog.entries.first?.amount, 15)
    }
}
