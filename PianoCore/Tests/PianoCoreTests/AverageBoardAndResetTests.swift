//
//  AverageBoardAndResetTests.swift — the practice-average board (the client's clarified
//  "All-Time" board) and the per-student practice reset (a testing aid). Pure, no I/O.
//

import XCTest
@testable import PianoCore

final class AverageBoardAndResetTests: XCTestCase {

    private func t(_ s: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }

    // MARK: - Average board

    /// Alice logs 10 + 20 on one day (avg 30), Bob logs 10 (avg 10), Cara nothing (avg 0).
    /// The board ranks by average, highest first, with dense placement.
    func testAverageBoardRanksByDailyAverage() {
        let sA = UUID(); let sB = UUID(); let sC = UUID()
        let mID = UUID()
        let entries = [
            CombatLogEntry(sequence: 0, studentID: sA, monsterRecordID: mID, amount: 10, timestamp: t(1_000_000)),
            CombatLogEntry(sequence: 1, studentID: sA, monsterRecordID: mID, amount: 20, timestamp: t(1_000_000)),
            CombatLogEntry(sequence: 2, studentID: sB, monsterRecordID: mID, amount: 10, timestamp: t(1_000_000)),
        ]
        let state = AppState(
            students: [Student(id: sA, name: "Alice", createdAt: t(0)),
                       Student(id: sB, name: "Bob", createdAt: t(0)),
                       Student(id: sC, name: "Cara", createdAt: t(0))],
            combatLog: CombatLog(entries: entries, nextSequence: 3)
        )

        let board = Leaderboards.averageBoard(state: state, now: t(1_000_100))
        XCTAssertEqual(board.map { $0.id }, [sA, sB, sC])
        XCTAssertEqual(board.map { $0.rank }, [1, 2, 3])
        XCTAssertEqual(board.first { $0.id == sA }?.average, 30)
        XCTAssertEqual(board.first { $0.id == sB }?.average, 10)
        XCTAssertEqual(board.first { $0.id == sC }?.average, 0)
    }

    /// Equal averages share a placement; the next distinct average gets the next number.
    func testAverageBoardUsesDensePlacementForTies() {
        let sA = UUID(); let sB = UUID(); let sC = UUID()
        let mID = UUID()
        let entries = [
            CombatLogEntry(sequence: 0, studentID: sA, monsterRecordID: mID, amount: 10, timestamp: t(1_000_000)),
            CombatLogEntry(sequence: 1, studentID: sB, monsterRecordID: mID, amount: 10, timestamp: t(1_000_000)),
        ]
        let state = AppState(
            students: [Student(id: sA, name: "Ann", createdAt: t(0)),
                       Student(id: sB, name: "Bea", createdAt: t(0)),
                       Student(id: sC, name: "Cy", createdAt: t(0))],
            combatLog: CombatLog(entries: entries, nextSequence: 2)
        )
        let board = Leaderboards.averageBoard(state: state, now: t(1_000_100))
        // Ann & Bea tie at 10 → both rank 1; Cara at 0 → rank 2 (no gap).
        XCTAssertEqual(board.first { $0.id == sA }?.rank, 1)
        XCTAssertEqual(board.first { $0.id == sB }?.rank, 1)
        XCTAssertEqual(board.first { $0.id == sC }?.rank, 2)
    }

    /// Migration seeds inflate leaderboard damage but must NOT count toward the average
    /// board (the daily-average definition already excludes them).
    func testAverageBoardExcludesMigrationSeedsAndInactiveStudents() {
        let sA = UUID(); let sInactive = UUID()
        let mID = UUID()
        let entries = [
            CombatLogEntry(sequence: 0, studentID: sA, monsterRecordID: mID, amount: 99,
                           timestamp: t(1_000_000), origin: .migration),
        ]
        let state = AppState(
            students: [Student(id: sA, name: "Alice", createdAt: t(0)),
                       Student(id: sInactive, name: "Gone", createdAt: t(0), isActive: false)],
            combatLog: CombatLog(entries: entries, nextSequence: 1)
        )
        let board = Leaderboards.averageBoard(state: state, now: t(1_000_100))
        XCTAssertEqual(board.map { $0.id }, [sA])          // inactive excluded
        XCTAssertEqual(board.first?.average, 0)             // migration seed doesn't count
    }

    // MARK: - Per-student reset

    func testResetStudentPracticeWipesOnlyThatStudent() {
        let team = UUID(); let sA = UUID(); let sB = UUID(); let mID = UUID(); let tpl = UUID()
        var state = AppState(
            students: [Student(id: sA, name: "A", teamID: team, createdAt: t(0)),
                       Student(id: sB, name: "B", teamID: team, createdAt: t(0))],
            teams: [Team(id: team, name: "T")],
            monsterCatalog: [MonsterTemplate(id: tpl, name: "M", kind: .regular)],
            ledger: [MonsterRecord(id: mID, templateID: tpl, kind: .regular, teamID: team,
                                   spawnedAt: t(0), spawnSequence: 0, killTargetWeeks: 3, legacyFixedHP: 1000)],
            settings: GameSettings(minimumMonsterHP: 5)
        )
        _ = try! GameEngine.attack(into: &state, targetRecordID: mID, studentID: sA, amount: 10, at: t(100)).get()
        _ = try! GameEngine.attack(into: &state, targetRecordID: mID, studentID: sA, amount: 5, at: t(200)).get()
        _ = try! GameEngine.attack(into: &state, targetRecordID: mID, studentID: sB, amount: 7, at: t(300)).get()
        XCTAssertEqual(state.actions.count, 3)
        XCTAssertEqual(state.damageDealt(toMonster: mID), 22)

        GameEngine.resetStudentPractice(into: &state, studentID: sA)

        // A is wiped; B is untouched.
        XCTAssertTrue(state.combatLog.entries.filter { $0.studentID == sA }.isEmpty)
        XCTAssertEqual(state.combatLog.entries.filter { $0.studentID == sB }.count, 1)
        XCTAssertEqual(state.damageDealt(toMonster: mID), 7)

        let cal = state.settings.resolvedCalendar
        XCTAssertEqual(PracticeMath.dailyAverage(forStudent: sA, entries: state.combatLog.entries,
                                                 now: t(400), calendar: cal), 0)

        // A's two actions are dropped; B's one action remains and is still coherently undoable.
        XCTAssertEqual(state.actions.count, 1)
        XCTAssertTrue(GameEngine.undoLast(into: &state, teamScope: team))
        XCTAssertEqual(state.damageDealt(toMonster: mID), 0)
        XCTAssertTrue(state.monsterRecord(mID)?.isAlive == true)   // monster never corrupted
    }

    func testResetStudentPracticeIsANoOpForAStudentWithNoHistory() {
        let sA = UUID()
        var state = AppState(students: [Student(id: sA, name: "A", createdAt: t(0))])
        let before = state
        GameEngine.resetStudentPractice(into: &state, studentID: sA)
        XCTAssertEqual(state, before)
    }
}
