//
//  CarryoverUndoTests.swift — the client-flagged high-risk logic: overkill carryover
//  and its full reversal. Pure, no filesystem.
//
//  Fixture design: the team has NO members and the attacking student is unassigned,
//  so every spawned successor has empty frozen averages and its HP is exactly the
//  minimumMonsterHP floor (pinned to 5 here). That makes chain arithmetic fully
//  deterministic: first monster 10 HP (legacy pin), every successor exactly 5 HP.
//
//  "Bit-identical" caveat: sequence numbers are never reused by design, so undo does
//  not roll `nextSequence` back. The comparisons below assert full-state equality
//  with only that counter normalized.
//

import XCTest
@testable import PianoCore

final class CarryoverUndoTests: XCTestCase {

    private func t(_ s: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }

    /// One team with no members, one unassigned student, two regular templates, one
    /// alive monster pinned at `hp`. minimumMonsterHP = 5 → every successor HP = 5.
    private func makeState(hp: Int = 10)
        -> (state: AppState, team: UUID, student: UUID, monster: UUID) {
        let team = UUID(); let stu = UUID(); let t1 = UUID(); let t2 = UUID(); let monsterID = UUID()
        let state = AppState(
            students: [Student(id: stu, name: "S1", teamID: nil, createdAt: t(0))], // NOT on the team
            teams: [Team(id: team, name: "Reds")],                                   // no members
            monsterCatalog: [
                MonsterTemplate(id: t1, name: "M1", kind: .regular),
                MonsterTemplate(id: t2, name: "M2", kind: .regular),
            ],
            ledger: [MonsterRecord(id: monsterID, templateID: t1, kind: .regular, teamID: team,
                                   spawnedAt: t(0), spawnSequence: 0, killTargetWeeks: 3,
                                   legacyFixedHP: hp)],
            settings: GameSettings(minimumMonsterHP: 5)
        )
        return (state, team, stu, monsterID)
    }

    private func assertEqualModuloSequenceCounter(_ actual: AppState, _ expected: AppState,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        var adjusted = expected
        adjusted.combatLog = CombatLog(entries: expected.combatLog.entries,
                                       nextSequence: actual.combatLog.nextSequence)
        XCTAssertEqual(actual, adjusted, file: file, line: line)
    }

    /// Basic carryover: 4 then 9 vs 10 HP → capped 6 kills, 3 carries to the successor.
    func testCarryoverLandsLeftoverOnSuccessor() {
        var (state, team, stu, monster) = makeState(hp: 10)
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 4, at: t(100)).get()
        let kill = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 9, at: t(200)).get()

        XCTAssertEqual(kill.entries.map { $0.amount }, [6, 3])
        XCTAssertEqual(kill.defeats.count, 1)
        let successor = state.aliveRegularRecord(forTeam: team)!
        XCTAssertEqual(state.effectiveHP(of: successor), 5)      // empty averages → floor
        XCTAssertEqual(state.damageDealt(toMonster: successor.id), 3)
        XCTAssertEqual(state.remainingHP(of: successor), 2)
        // The dying monster is credited only the capped 6 (plus the earlier 4).
        XCTAssertEqual(state.monsterRecord(monster)?.finalLeaderboard?.first?.totalDamage, 10)
    }

    /// Client edge case: overkill EXACTLY equal to the successor's full HP — the
    /// carryover kills the successor outright, and a third monster spawns clean.
    func testOverkillExactlyEqualToSuccessorFullHP() {
        var (state, team, stu, monster) = makeState(hp: 10)
        let before = state

        // 15 vs 10 HP → capped 10 kills M1, leftover 5 == successor's full 5 HP →
        // carryover entry of 5 kills the successor too → a third monster spawns clean.
        let result = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 15, at: t(100)).get()

        XCTAssertEqual(result.entries.map { $0.amount }, [10, 5])
        XCTAssertEqual(result.defeats.count, 2)                    // M1 AND its successor died
        XCTAssertEqual(state.ledger.count, 3)                      // M1, S1 (both dead), S2 alive
        let third = state.aliveRegularRecord(forTeam: team)!
        XCTAssertEqual(state.damageDealt(toMonster: third.id), 0)  // zero leftover → no entry
        // The instantly-killed successor's board credits exactly its 5 HP.
        let s1 = state.ledger.first { !$0.isAlive && $0.id != monster }!
        XCTAssertEqual(s1.finalLeaderboard?.first?.totalDamage, 5)

        // ONE undo reverses the whole two-kill chain: world bit-identical to before.
        XCTAssertTrue(GameEngine.undoLast(into: &state, teamScope: team))
        assertEqualModuloSequenceCounter(state, before)
    }

    /// Client edge case: multiple sequential overkills, then multiple undos — each
    /// undo steps the world back exactly one attack, ending bit-identical to the start.
    func testMultipleSequentialOverkillsThenMultipleUndos() {
        var (state, team, stu, monster) = makeState(hp: 10)
        let s0 = state

        // Attack 1: 12 vs M1(10) → capped 10 kills M1, leftover 2 lands on S1(5).
        let a1 = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 12, at: t(100)).get()
        XCTAssertEqual(a1.entries.map { $0.amount }, [10, 2])
        XCTAssertEqual(a1.defeats.count, 1)
        let s1Snapshot = state

        // Attack 2: 9 vs S1 (2/5 dealt, 3 remaining) → capped 3 kills S1, leftover 6
        // vs S2(5) → capped 5 kills S2, leftover 1 lands on S3(5). A two-kill chain.
        let s1ID = state.aliveRegularRecord(forTeam: team)!.id
        let a2 = try! GameEngine.attack(into: &state, targetRecordID: s1ID, studentID: stu, amount: 9, at: t(200)).get()
        XCTAssertEqual(a2.entries.map { $0.amount }, [3, 5, 1])
        XCTAssertEqual(a2.defeats.count, 2)
        XCTAssertEqual(state.ledger.count, 4)                          // M1, S1, S2 dead + S3 alive
        XCTAssertEqual(state.ledger.filter { $0.isAlive }.count, 1)
        // Each dead monster's frozen board credits exactly what killed it.
        XCTAssertEqual(state.monsterRecord(monster)?.finalLeaderboard?.first?.totalDamage, 10)
        XCTAssertEqual(state.monsterRecord(s1ID)?.finalLeaderboard?.first?.totalDamage, 5) // 2 + capped 3
        let s3 = state.aliveRegularRecord(forTeam: team)!
        XCTAssertEqual(state.damageDealt(toMonster: s3.id), 1)

        // Undo attack 2 → exactly the post-attack-1 world.
        XCTAssertTrue(GameEngine.undoLast(into: &state, teamScope: team))
        assertEqualModuloSequenceCounter(state, s1Snapshot)
        // The revived S1 is back at 2/5 dealt, 3 remaining.
        let revivedS1 = state.aliveRegularRecord(forTeam: team)!
        XCTAssertEqual(revivedS1.id, s1ID)
        XCTAssertEqual(state.remainingHP(of: revivedS1), 3)

        // Undo attack 1 → exactly the initial world.
        XCTAssertTrue(GameEngine.undoLast(into: &state, teamScope: team))
        assertEqualModuloSequenceCounter(state, s0)
        XCTAssertTrue(state.monsterRecord(monster)!.isAlive)
        XCTAssertEqual(state.remainingHP(of: state.monsterRecord(monster)!), 10)
        XCTAssertFalse(GameEngine.undoLast(into: &state, teamScope: team)) // nothing left
    }

    /// A single attack's chain is ONE action: undoing after a chain removes the whole
    /// chain, never half of it.
    func testChainIsAtomicInTheActionHistory() {
        var (state, team, stu, monster) = makeState(hp: 10)
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 15, at: t(100)).get()
        XCTAssertEqual(state.actions.count, 1)          // two kills, one action
        XCTAssertEqual(state.combatLog.entries.count, 2)
        XCTAssertTrue(GameEngine.undoLast(into: &state, teamScope: team))
        XCTAssertEqual(state.actions.count, 0)
        XCTAssertEqual(state.combatLog.entries.count, 0)
        XCTAssertEqual(state.ledger.count, 1)
    }
}
