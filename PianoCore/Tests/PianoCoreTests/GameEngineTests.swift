//
//  GameEngineTests.swift — the game logic: attack/defeat with carryover, backdoor
//  controls, and the unified undo (including kill reversal). Pure, no filesystem.
//
//  The first monster's HP is pinned via legacyFixedHP so these tests isolate the
//  engine flow from the averaging math (which has its own suite). Successor HP is
//  formula-derived; where a test asserts it, the expectation is computed in a comment.
//

import XCTest
@testable import PianoCore

final class GameEngineTests: XCTestCase {

    private func t(_ s: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }

    /// Base fixture: one team, one student on it, a catalog of two regular templates,
    /// and one alive monster with a pinned HP of `hp`.
    private func makeState(hp: Int = 10)
        -> (state: AppState, team: UUID, student: UUID, monster: UUID, t1: UUID, t2: UUID) {
        let team = UUID(); let stu = UUID(); let t1 = UUID(); let t2 = UUID(); let monsterID = UUID()
        let student = Student(id: stu, name: "S1", teamID: team, createdAt: t(0))
        let catalog = [
            MonsterTemplate(id: t1, name: "M1", kind: .regular),
            MonsterTemplate(id: t2, name: "M2", kind: .regular),
        ]
        let monster = MonsterRecord(id: monsterID, templateID: t1, kind: .regular, teamID: team,
                                    spawnedAt: t(0), spawnSequence: 0, killTargetWeeks: 3,
                                    legacyFixedHP: hp)
        let state = AppState(students: [student], teams: [Team(id: team, name: "Reds")],
                             monsterCatalog: catalog, ledger: [monster])
        return (state, team, stu, monsterID, t1, t2)
    }

    /// Asserts two states are identical except for the never-reused sequence counter
    /// (undo removes entries but intentionally does not roll `nextSequence` back).
    private func assertEqualModuloSequenceCounter(_ actual: AppState, _ expected: AppState,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        var adjusted = expected
        adjusted.combatLog = CombatLog(entries: expected.combatLog.entries,
                                       nextSequence: actual.combatLog.nextSequence)
        XCTAssertEqual(actual, adjusted, file: file, line: line)
    }

    func testAttackReducesRemainingHPWithoutKilling() {
        var (state, _, stu, monster, _, _) = makeState(hp: 10)
        let result = try! GameEngine.attack(into: &state, targetRecordID: monster,
                                            studentID: stu, amount: 4, at: t(100)).get()
        XCTAssertFalse(result.killed)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.defeats.count, 0)
        XCTAssertEqual(state.combatLog.entries.count, 1)
        XCTAssertEqual(state.actions.count, 1)
        let rec = state.monsterRecord(monster)!
        XCTAssertTrue(rec.isAlive)
        XCTAssertEqual(state.remainingHP(of: rec), 6)
        XCTAssertEqual(state.ledger.count, 1) // no successor yet
    }

    func testKillCapsEntrySpawnsSuccessorAndCarriesOverflow() {
        var (state, team, stu, monster, t1, t2) = makeState(hp: 10)
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 4, at: t(100)).get()
        let kill = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 9, at: t(200)).get()

        XCTAssertTrue(kill.killed)
        // Carryover: the killing entry is CAPPED at the remaining HP (6); the leftover
        // (3) lands on the successor as its own entry. Same student, same timestamp.
        XCTAssertEqual(kill.entries.map { $0.amount }, [6, 3])
        XCTAssertEqual(kill.defeats.count, 1)
        XCTAssertEqual(kill.entries[1].timestamp, t(200))
        XCTAssertEqual(kill.entries[1].studentID, stu)

        // Defeated record: frozen board credits exactly the damage that killed it
        // (4 + capped 6 = 10), NOT the carried-over 3.
        let defeated = state.monsterRecord(monster)!
        XCTAssertFalse(defeated.isAlive)
        XCTAssertEqual(defeated.finalLeaderboard?.first?.totalDamage, 10)
        XCTAssertEqual(defeated.finalLeaderboard?.first?.rank, 1)

        // Successor: alive, same team, next template (t2), carrying exactly 3 damage.
        XCTAssertEqual(state.ledger.count, 2)
        let successor = state.aliveRegularRecord(forTeam: team)!
        XCTAssertEqual(successor.templateID, t2)
        XCTAssertNotEqual(t1, t2)
        XCTAssertEqual(state.damageDealt(toMonster: successor.id), 3)
        XCTAssertEqual(kill.entries[1].monsterRecordID, successor.id)
        XCTAssertEqual(successor.spawnedByEntryID, kill.entries[0].id)

        // Successor HP from frozen averages: live entries 4 + 6 on one calendar day
        // → daily average 10 → ceil(10 × 3 weeks) = 30. Carry 3 → remaining 27.
        XCTAssertEqual(state.effectiveHP(of: successor), 30)
        XCTAssertEqual(state.remainingHP(of: successor), 27)

        // One action per attack; the kill+carry chain is ONE action.
        XCTAssertEqual(state.actions.count, 2)
    }

    func testUndoNormalAttackRestoresState() {
        var (state, team, stu, monster, _, _) = makeState(hp: 10)
        let before = state
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 4, at: t(100)).get()

        XCTAssertTrue(GameEngine.undoLast(into: &state, teamScope: team))
        assertEqualModuloSequenceCounter(state, before)
        // Nothing left to undo.
        XCTAssertFalse(GameEngine.undoLast(into: &state, teamScope: team))
    }

    func testUndoAcrossKillReversesKillSpawnCarryAndLockIn() {
        var (state, team, stu, monster, _, _) = makeState(hp: 10)
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 4, at: t(100)).get()
        let beforeKill = state
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 9, at: t(200)).get()
        XCTAssertEqual(state.ledger.count, 2)

        // Undo the kill+carry chain in one step.
        XCTAssertTrue(GameEngine.undoLast(into: &state, teamScope: team))

        let revived = state.monsterRecord(monster)!
        XCTAssertTrue(revived.isAlive)              // kill reversed
        XCTAssertNil(revived.finalLeaderboard)      // lock-in cleared
        XCTAssertNil(revived.defeatedByEntryID)
        XCTAssertEqual(state.ledger.count, 1)       // successor (and its carry) gone
        XCTAssertEqual(state.combatLog.entries.count, 1) // only the first (4) remains
        XCTAssertEqual(state.remainingHP(of: revived), 6)
        XCTAssertEqual(state.actions.count, 1)

        // The world is bit-identical to just before the kill (modulo the counter).
        assertEqualModuloSequenceCounter(state, beforeKill)
    }

    func testAdjustHPAppliesAndUndoes() {
        var (state, team, _, monster, _, _) = makeState(hp: 10)
        _ = try! GameEngine.adjustHP(into: &state, recordID: monster, delta: -3, at: t(100)).get()
        XCTAssertEqual(state.effectiveHP(of: state.monsterRecord(monster)!), 7)

        XCTAssertTrue(GameEngine.undoLast(into: &state, teamScope: team))
        XCTAssertEqual(state.effectiveHP(of: state.monsterRecord(monster)!), 10)
        XCTAssertEqual(state.actions.count, 0)
    }

    func testSetKillTargetRecomputesHPFromFrozenAveragesAndUndoes() {
        // Build a monster whose HP comes from the formula (averages × weeks), not a pin.
        let team = UUID(); let stu = UUID(); let monsterID = UUID(); let t1 = UUID()
        let monster = MonsterRecord(id: monsterID, templateID: t1, kind: .regular, teamID: team,
                                    spawnedAt: Date(timeIntervalSince1970: 0), spawnSequence: 0,
                                    spawnAverages: [StudentAverage(studentID: stu, average: 10)],
                                    killTargetWeeks: 3) // 10 × 3 = 30
        var state = AppState(students: [Student(id: stu, name: "S1", teamID: team, createdAt: t(0))],
                             teams: [Team(id: team, name: "Reds")],
                             monsterCatalog: [MonsterTemplate(id: t1, name: "M1", kind: .regular)],
                             ledger: [monster])

        XCTAssertEqual(state.effectiveHP(of: state.monsterRecord(monsterID)!), 30)
        _ = try! GameEngine.setKillTarget(into: &state, recordID: monsterID, weeks: 6, at: t(100)).get()
        XCTAssertEqual(state.effectiveHP(of: state.monsterRecord(monsterID)!), 60) // 10 × 6

        XCTAssertTrue(GameEngine.undoLast(into: &state, teamScope: team))
        XCTAssertEqual(state.effectiveHP(of: state.monsterRecord(monsterID)!), 30)
    }

    func testAutokillFreezesBoardSpawnsSuccessorAndUndoes() {
        var (state, team, stu, monster, _, t2) = makeState(hp: 100)
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 5, at: t(100)).get()

        let outcome = try! GameEngine.autokill(into: &state, recordID: monster, at: t(200)).get()
        XCTAssertEqual(outcome.reason, .autokill)
        XCTAssertFalse(state.monsterRecord(monster)!.isAlive)
        XCTAssertEqual(state.monsterRecord(monster)!.finalLeaderboard?.first?.totalDamage, 5)
        let successor = state.aliveRegularRecord(forTeam: team)!
        XCTAssertEqual(successor.templateID, t2)
        XCTAssertEqual(state.damageDealt(toMonster: successor.id), 0) // autokill never carries

        // Undo the autokill: monster revives, successor removed, the prior attack stays.
        XCTAssertTrue(GameEngine.undoLast(into: &state, teamScope: team))
        XCTAssertTrue(state.monsterRecord(monster)!.isAlive)
        XCTAssertEqual(state.ledger.count, 1)
        XCTAssertEqual(state.combatLog.entries.count, 1)
    }

    func testBackdoorControlsRejectDefeatedMonsters() {
        var (state, _, stu, monster, _, _) = makeState(hp: 5)
        // Exact kill: capped entry of 5, zero leftover — successor spawns with no carry.
        let kill = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 5, at: t(100)).get()
        XCTAssertEqual(kill.entries.map { $0.amount }, [5])
        XCTAssertFalse(state.monsterRecord(monster)!.isAlive)

        if case .failure(let e) = GameEngine.adjustHP(into: &state, recordID: monster, delta: 10, at: t(200)) {
            XCTAssertEqual(e, .monsterAlreadyDefeated)
        } else { XCTFail("adjustHP must reject a defeated monster") }

        if case .failure(let e) = GameEngine.setKillTarget(into: &state, recordID: monster, weeks: 9, at: t(200)) {
            XCTAssertEqual(e, .monsterAlreadyDefeated)
        } else { XCTFail("setKillTarget must reject a defeated monster") }
    }

    func testTeamScopedUndoIgnoresOtherTeamsActions() {
        // Two teams, each with its own alive monster and one student.
        let teamA = UUID(); let teamB = UUID()
        let sA = UUID(); let sB = UUID()
        let mA = UUID(); let mB = UUID(); let tpl = UUID()
        var state = AppState(
            students: [Student(id: sA, name: "A", teamID: teamA, createdAt: t(0)),
                       Student(id: sB, name: "B", teamID: teamB, createdAt: t(0))],
            teams: [Team(id: teamA, name: "Reds"), Team(id: teamB, name: "Blues")],
            monsterCatalog: [MonsterTemplate(id: tpl, name: "M", kind: .regular)],
            ledger: [
                MonsterRecord(id: mA, templateID: tpl, kind: .regular, teamID: teamA,
                              spawnedAt: t(0), spawnSequence: 0, killTargetWeeks: 3, legacyFixedHP: 100),
                MonsterRecord(id: mB, templateID: tpl, kind: .regular, teamID: teamB,
                              spawnedAt: t(0), spawnSequence: 1, killTargetWeeks: 3, legacyFixedHP: 100),
            ]
        )
        _ = try! GameEngine.attack(into: &state, targetRecordID: mA, studentID: sA, amount: 5, at: t(100)).get()
        _ = try! GameEngine.attack(into: &state, targetRecordID: mB, studentID: sB, amount: 7, at: t(200)).get()

        // Undo scoped to team A removes A's attack even though B's is more recent.
        XCTAssertTrue(GameEngine.undoLast(into: &state, teamScope: teamA))
        XCTAssertEqual(state.damageDealt(toMonster: mA), 0) // A's attack gone
        XCTAssertEqual(state.damageDealt(toMonster: mB), 7) // B's attack intact
        XCTAssertEqual(state.actions.count, 1)
    }

    func testAttackValidationErrors() {
        var (state, _, stu, monster, _, _) = makeState(hp: 10)
        // Negative amount rejected, state untouched.
        if case .failure(let e) = GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: -1, at: t(1)) {
            XCTAssertEqual(e, .negativeAmount)
        } else { XCTFail("expected negativeAmount") }
        // Unknown monster.
        if case .failure(let e) = GameEngine.attack(into: &state, targetRecordID: UUID(), studentID: stu, amount: 1, at: t(1)) {
            XCTAssertEqual(e, .monsterNotFound)
        } else { XCTFail("expected monsterNotFound") }
        XCTAssertEqual(state.combatLog.entries.count, 0) // no partial mutation on failure
    }
}
