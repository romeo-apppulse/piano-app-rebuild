//
//  LeaderboardsTests.swift — dense ranking and the three distinct boards.
//

import XCTest
@testable import PianoCore

final class LeaderboardsTests: XCTestCase {

    private func student(_ name: String, team: UUID? = nil) -> Student {
        Student(name: name, teamID: team, createdAt: Date(timeIntervalSince1970: 0))
    }
    private func entry(_ student: UUID, _ amount: Int, monster: UUID,
                       origin: EntryOrigin = .live, seq: Int = 0) -> CombatLogEntry {
        CombatLogEntry(sequence: seq, studentID: student, monsterRecordID: monster,
                       amount: amount, timestamp: Date(timeIntervalSince1970: 0), origin: origin)
    }

    /// The client's exact worked example: two students tied at 439 are BOTH "1st
    /// place"; the next student is "2nd place" (not 3rd).
    func testClientTieExampleSharedPlacementAndNextNumber() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let rows = Leaderboards.ranked([
            (id: a, name: "Ann", total: 439),
            (id: b, name: "Bob", total: 439),
            (id: c, name: "Cy",  total: 300),
        ])
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byId[a]?.rank, 1)   // tied at 439 → both 1st
        XCTAssertEqual(byId[b]?.rank, 1)
        XCTAssertEqual(byId[c]?.rank, 2)   // next student is 2nd, NOT 3rd
    }

    /// The same rule holds deeper in the board: 1st, 2nd-tie, 2nd-tie, 3rd.
    func testSharedPlacementCascadesThroughTheBoard() {
        let a = UUID(); let b = UUID(); let c = UUID(); let d = UUID()
        let rows = Leaderboards.ranked([
            (id: a, name: "Ann", total: 50),
            (id: b, name: "Bob", total: 10),
            (id: c, name: "Cy",  total: 10),
            (id: d, name: "Di",  total: 5),
        ])
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byId[a]?.rank, 1)
        XCTAssertEqual(byId[b]?.rank, 2)   // tie shares 2nd
        XCTAssertEqual(byId[c]?.rank, 2)
        XCTAssertEqual(byId[d]?.rank, 3)   // next number, no gap
    }

    func testCurrentMonsterIsScopedToOneInstanceAndResetsAcrossMonsters() {
        let team = UUID()
        let s1 = student("S1", team: team); let s2 = student("S2", team: team)
        let m1 = UUID(); let m2 = UUID() // two monster instances

        let state = AppState(
            students: [s1, s2],
            teams: [Team(id: team, name: "Reds")],
            combatLog: CombatLog(entries: [
                entry(s1.id, 30, monster: m1, seq: 0),
                entry(s2.id, 10, monster: m1, seq: 1),
                entry(s2.id, 99, monster: m2, seq: 2), // belongs to the OTHER monster
            ], nextSequence: 3)
        )

        let board1 = Leaderboards.currentMonster(recordID: m1, state: state)
        XCTAssertEqual(board1.count, 2)
        XCTAssertEqual(board1.first?.id, s1.id)            // 30 beats 10
        XCTAssertEqual(board1.first?.totalDamage, 30)

        let board2 = Leaderboards.currentMonster(recordID: m2, state: state)
        XCTAssertEqual(board2.count, 1)                     // only s2 hit m2
        XCTAssertEqual(board2.first?.totalDamage, 99)
    }

    func testAllTimeSumsAcrossMonstersIncludingMigrationAndListsZeroDamageStudents() {
        let s1 = student("S1"); let s2 = student("S2"); let s3 = student("S3")
        let m1 = UUID(); let m2 = UUID()

        let state = AppState(
            students: [s1, s2, s3],
            combatLog: CombatLog(entries: [
                entry(s1.id, 20, monster: m1, seq: 0),
                entry(s1.id, 5,  monster: m2, seq: 1),                       // s1 lifetime = 25
                entry(s2.id, 7,  monster: m1, origin: .migration, seq: 2),   // migration counts here
            ], nextSequence: 3)
        )

        let board = Leaderboards.allTime(state: state)
        let byId = Dictionary(uniqueKeysWithValues: board.map { ($0.id, $0) })
        XCTAssertEqual(byId[s1.id]?.totalDamage, 25)
        XCTAssertEqual(byId[s2.id]?.totalDamage, 7)        // migration seed included
        XCTAssertEqual(byId[s3.id]?.totalDamage, 0)        // zero-damage active student still listed
        XCTAssertEqual(board.count, 3)
        XCTAssertEqual(board.first?.id, s1.id)             // ranked highest
    }

    func testAllTimeExcludesSoftDeletedStudentsButListsActiveOnesAtZero() {
        var s1 = student("S1"); let s2 = student("S2")
        s1.isActive = false                       // removed, but keeps its history
        let m = UUID()
        let state = AppState(
            students: [s1, s2],
            combatLog: CombatLog(entries: [
                entry(s1.id, 50, monster: m, seq: 0), // damage exists but student is hidden
            ], nextSequence: 1)
        )
        let board = Leaderboards.allTime(state: state)
        let ids = Set(board.map { $0.id })
        XCTAssertFalse(ids.contains(s1.id)) // soft-deleted hidden despite having damage
        XCTAssertTrue(ids.contains(s2.id))  // active student listed even at 0
        XCTAssertEqual(board.count, 1)
        XCTAssertEqual(board.first?.totalDamage, 0)
    }

    func testPastMonsterReturnsTheTeamsMostRecentlyDefeatedSnapshot() {
        let team = UUID()
        let s1 = student("S1", team: team)
        let frozen = [LeaderboardSnapshotRow(id: s1.id, displayName: "S1", totalDamage: 42, rank: 1)]

        let older = MonsterRecord(templateID: UUID(), kind: .regular, teamID: team,
                                  spawnedAt: Date(timeIntervalSince1970: 0), spawnSequence: 0,
                                  killTargetWeeks: 3, defeatedAt: Date(timeIntervalSince1970: 10),
                                  finalLeaderboard: [])
        let previous = MonsterRecord(templateID: UUID(), kind: .regular, teamID: team,
                                     spawnedAt: Date(timeIntervalSince1970: 20), spawnSequence: 1,
                                     killTargetWeeks: 3, defeatedAt: Date(timeIntervalSince1970: 30),
                                     finalLeaderboard: frozen)
        let alive = MonsterRecord(templateID: UUID(), kind: .regular, teamID: team,
                                  spawnedAt: Date(timeIntervalSince1970: 40), spawnSequence: 2,
                                  killTargetWeeks: 3) // current, not defeated

        let state = AppState(students: [s1], teams: [Team(id: team, name: "Reds")],
                             ledger: [older, previous, alive])

        let past = Leaderboards.pastMonster(forTeam: team, state: state)
        XCTAssertEqual(past, frozen) // the most-recently-defeated (spawnSequence 1), not the older one
    }
}
