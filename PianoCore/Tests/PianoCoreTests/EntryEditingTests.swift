//
//  EntryEditingTests.swift — the client's entry policy: only the MOST RECENT entry is
//  editable/deletable; older entries are locked; delete == undo. Pure, no filesystem.
//

import XCTest
@testable import PianoCore

final class EntryEditingTests: XCTestCase {

    private func t(_ s: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }

    /// One team with one student on it, two templates, one monster pinned at `hp`.
    private func makeState(hp: Int = 10)
        -> (state: AppState, team: UUID, student: UUID, monster: UUID) {
        let team = UUID(); let stu = UUID(); let t1 = UUID(); let t2 = UUID(); let monsterID = UUID()
        let state = AppState(
            students: [Student(id: stu, name: "S1", teamID: team, createdAt: t(0))],
            teams: [Team(id: team, name: "Reds")],
            monsterCatalog: [
                MonsterTemplate(id: t1, name: "M1", kind: .regular),
                MonsterTemplate(id: t2, name: "M2", kind: .regular),
            ],
            ledger: [MonsterRecord(id: monsterID, templateID: t1, kind: .regular, teamID: team,
                                   spawnedAt: t(0), spawnSequence: 0, killTargetWeeks: 3,
                                   legacyFixedHP: hp)]
        )
        return (state, team, stu, monsterID)
    }

    func testEditMostRecentChangesAmountAndPreservesStudentTargetTimestamp() {
        var (state, team, stu, monster) = makeState(hp: 10)
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 4, at: t(100)).get()

        let edited = try! GameEngine.editMostRecentAttack(into: &state, teamScope: team, newAmount: 7).get()

        XCTAssertEqual(state.combatLog.entries.count, 1)
        XCTAssertEqual(edited.entries.map { $0.amount }, [7])
        XCTAssertEqual(edited.entries[0].studentID, stu)
        XCTAssertEqual(edited.entries[0].monsterRecordID, monster)
        XCTAssertEqual(edited.entries[0].timestamp, t(100))   // original timestamp kept
        XCTAssertEqual(state.remainingHP(of: state.monsterRecord(monster)!), 3)
        XCTAssertEqual(state.actions.count, 1)                // still one attack action
    }

    func testEditTurnsKillIntoPlainHitReversingSpawnAndLockIn() {
        var (state, team, stu, monster) = makeState(hp: 10)
        // 12 kills the monster (capped 10) and carries 2 onto the successor.
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 12, at: t(100)).get()
        XCTAssertFalse(state.monsterRecord(monster)!.isAlive)
        XCTAssertEqual(state.ledger.count, 2)

        // Editing down to 3 must reverse the kill, the spawn, the carry, the lock-in.
        let edited = try! GameEngine.editMostRecentAttack(into: &state, teamScope: team, newAmount: 3).get()

        XCTAssertFalse(edited.killed)
        XCTAssertTrue(state.monsterRecord(monster)!.isAlive)
        XCTAssertNil(state.monsterRecord(monster)!.finalLeaderboard)
        XCTAssertEqual(state.ledger.count, 1)                 // successor gone
        XCTAssertEqual(state.combatLog.entries.count, 1)
        XCTAssertEqual(state.remainingHP(of: state.monsterRecord(monster)!), 7)
    }

    func testEditTurnsPlainHitIntoKillWithCarryover() {
        var (state, team, stu, monster) = makeState(hp: 10)
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 4, at: t(100)).get()

        let edited = try! GameEngine.editMostRecentAttack(into: &state, teamScope: team, newAmount: 15).get()

        XCTAssertTrue(edited.killed)
        // Re-applied at the original timestamp: capped 10 kills, 5 carries over.
        XCTAssertEqual(edited.entries.map { $0.amount }, [10, 5])
        XCTAssertFalse(state.monsterRecord(monster)!.isAlive)
        let successor = state.aliveRegularRecord(forTeam: team)!
        XCTAssertEqual(state.damageDealt(toMonster: successor.id), 5)
    }

    /// "Delete most recent" and "undo" must be the SAME operation — no divergence.
    func testDeleteMostRecentEntryIsExactlyUndo() {
        var (base, team, stu, monster) = makeState(hp: 10)
        _ = try! GameEngine.attack(into: &base, targetRecordID: monster, studentID: stu, amount: 4, at: t(100)).get()
        _ = try! GameEngine.attack(into: &base, targetRecordID: monster, studentID: stu, amount: 9, at: t(200)).get() // kill + carry

        var viaDelete = base
        var viaUndo = base
        _ = try! GameEngine.deleteMostRecentEntry(into: &viaDelete, teamScope: team).get()
        XCTAssertTrue(GameEngine.undoLast(into: &viaUndo, teamScope: team))

        XCTAssertEqual(viaDelete, viaUndo) // bit-identical, including the kill reversal
    }

    func testDeleteRefusedWhenMostRecentActionIsAdmin() {
        var (state, team, stu, monster) = makeState(hp: 10)
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 4, at: t(100)).get()
        _ = try! GameEngine.adjustHP(into: &state, recordID: monster, delta: -2, at: t(200)).get()

        if case .failure(let e) = GameEngine.deleteMostRecentEntry(into: &state, teamScope: team) {
            XCTAssertEqual(e, .noEditableEntry)
        } else { XCTFail("delete must refuse when the most recent action is an admin action") }
        XCTAssertEqual(state.combatLog.entries.count, 1) // nothing removed
        XCTAssertEqual(state.actions.count, 2)
    }

    func testEditRefusedWhenNothingToEdit() {
        var (state, team, _, _) = makeState(hp: 10)
        if case .failure(let e) = GameEngine.editMostRecentAttack(into: &state, teamScope: team, newAmount: 5) {
            XCTAssertEqual(e, .noEditableEntry)
        } else { XCTFail("edit must refuse with no attack in scope") }
    }

    /// Older entries are locked: editing the most recent leaves every earlier entry
    /// byte-for-byte untouched (same id, same amount, same everything).
    func testEditLeavesOlderEntriesUntouched() {
        var (state, team, stu, monster) = makeState(hp: 10)
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 4, at: t(100)).get()
        let lockedEntry = state.combatLog.entries[0]
        _ = try! GameEngine.attack(into: &state, targetRecordID: monster, studentID: stu, amount: 3, at: t(200)).get()

        _ = try! GameEngine.editMostRecentAttack(into: &state, teamScope: team, newAmount: 5).get()

        XCTAssertEqual(state.combatLog.entries.count, 2)
        let oldest = state.combatLog.entries.min(by: { $0.sequence < $1.sequence })!
        XCTAssertEqual(oldest, lockedEntry)                   // fully unchanged
        let newest = state.combatLog.entries.max(by: { $0.sequence < $1.sequence })!
        XCTAssertEqual(newest.amount, 5)
    }
}
