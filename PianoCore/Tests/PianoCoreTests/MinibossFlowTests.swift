//
//  MinibossFlowTests.swift — the client's miniboss mechanic: lineup-driven
//  auto-trigger, global pause, shared fight, lineup editing during the pause,
//  resume, and undo across every boundary. Pure, no filesystem.
//
//  Fixture design: both students are UNASSIGNED so team spawn-averages are empty and
//  every regular successor spawns at the minimumMonsterHP floor (5) — deterministic.
//  The miniboss sums ALL students' averages regardless of team, so its HP is driven
//  by the controlled attack amounts: sA logs 10 + 5 on one calendar day → average 15;
//  sB has no history → 0. Miniboss HP = ceil((15 + 0) × 6 weeks) = 90.
//

import XCTest
@testable import PianoCore

final class MinibossFlowTests: XCTestCase {

    private func t(_ s: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }

    private struct Fixture {
        var state: AppState
        let teamA: UUID, teamB: UUID
        let sA: UUID, sB: UUID
        let mA: UUID, mB: UUID
        let tplR1: UUID, tplR2: UUID, tplMB: UUID
        let slotR2: LineupSlot, slotMB: LineupSlot, slotR1: LineupSlot
    }

    /// Two teams (no members), two unassigned students, lineup [R2, MB, R1], and one
    /// alive pinned monster per team (A: 10 HP, B: 100 HP). Successor floor = 5 HP.
    private func makeFixture() -> Fixture {
        let teamA = UUID(); let teamB = UUID()
        let sA = UUID(); let sB = UUID()
        let mA = UUID(); let mB = UUID()
        let tplR1 = UUID(); let tplR2 = UUID(); let tplMB = UUID()
        let slotR2 = LineupSlot(templateID: tplR2)
        let slotMB = LineupSlot(templateID: tplMB)
        let slotR1 = LineupSlot(templateID: tplR1)

        let state = AppState(
            students: [Student(id: sA, name: "A", teamID: nil, createdAt: t(0)),
                       Student(id: sB, name: "B", teamID: nil, createdAt: t(0))],
            teams: [Team(id: teamA, name: "Reds"), Team(id: teamB, name: "Blues")],
            monsterCatalog: [
                MonsterTemplate(id: tplR1, name: "R1", kind: .regular),
                MonsterTemplate(id: tplR2, name: "R2", kind: .regular),
                MonsterTemplate(id: tplMB, name: "Boss", kind: .miniboss),
            ],
            lineup: [slotR2, slotMB, slotR1],
            ledger: [
                MonsterRecord(id: mA, templateID: tplR1, kind: .regular, teamID: teamA,
                              spawnedAt: t(0), spawnSequence: 0, killTargetWeeks: 3, legacyFixedHP: 10),
                MonsterRecord(id: mB, templateID: tplR1, kind: .regular, teamID: teamB,
                              spawnedAt: t(0), spawnSequence: 1, killTargetWeeks: 3, legacyFixedHP: 100),
            ],
            settings: GameSettings(minimumMonsterHP: 5)
        )
        return Fixture(state: state, teamA: teamA, teamB: teamB, sA: sA, sB: sB,
                       mA: mA, mB: mB, tplR1: tplR1, tplR2: tplR2, tplMB: tplMB,
                       slotR2: slotR2, slotMB: slotMB, slotR1: slotR1)
    }

    /// Team A kills mA (consumes slot R2), then kills the R2 successor — whose next
    /// slot is the miniboss → the global fight triggers. Returns the fixture mid-pause.
    private func makeTriggeredFixture() -> Fixture {
        var f = makeFixture()
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: f.mA, studentID: f.sA, amount: 10, at: t(100)).get()
        let succ = f.state.aliveRegularRecord(forTeam: f.teamA)!
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: succ.id, studentID: f.sA, amount: 5, at: t(200)).get()
        return f
    }

    // MARK: - Lineup consumption + trigger

    func testLineupDrivesSuccessorAndAdvancesPointer() {
        var f = makeFixture()
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: f.mA, studentID: f.sA, amount: 10, at: t(100)).get()

        let successor = f.state.aliveRegularRecord(forTeam: f.teamA)!
        XCTAssertEqual(successor.templateID, f.tplR2)              // from lineup slot 0
        XCTAssertEqual(successor.lineupSlotID, f.slotR2.id)
        XCTAssertEqual(f.state.effectiveHP(of: successor), 5)      // empty team → floor
        XCTAssertEqual(f.state.teams.first { $0.id == f.teamA }?.nextLineupIndex, 1)
        XCTAssertNil(f.state.aliveMiniboss)                        // not triggered yet
    }

    func testReachingMinibossSlotAutoTriggersGlobalFight() {
        let f = makeTriggeredFixture()

        let miniboss = f.state.aliveMiniboss
        XCTAssertNotNil(miniboss)
        XCTAssertEqual(miniboss?.templateID, f.tplMB)
        XCTAssertNil(miniboss?.teamID)                              // fought by everyone
        XCTAssertEqual(miniboss?.triggeredByTeamID, f.teamA)
        XCTAssertEqual(miniboss?.lineupSlotID, f.slotMB.id)         // slot is now spent
        XCTAssertTrue(f.state.isSpent(slot: f.slotMB))
        XCTAssertEqual(miniboss?.killTargetWeeks, 6)                // miniboss default
        // Frozen at trigger: sA avg 15 (10+5, one day), sB avg 0 → ceil(15 × 6) = 90.
        XCTAssertEqual(miniboss?.spawnAverages.count, 2)            // ALL students
        XCTAssertEqual(f.state.effectiveHP(of: miniboss!), 90)
        // Trigger does NOT advance the pointer — the spent rule consumes the slot.
        XCTAssertEqual(f.state.teams.first { $0.id == f.teamA }?.nextLineupIndex, 1)
    }

    // MARK: - The pause gate

    func testWhileMinibossAliveOnlyItCanBeTargeted() {
        var f = makeTriggeredFixture()

        // Team B's paused monster is untouchable — by attack AND by autokill.
        if case .failure(let e) = GameEngine.attack(into: &f.state, targetRecordID: f.mB, studentID: f.sB, amount: 3, at: t(300)) {
            XCTAssertEqual(e, .minibossActive)
        } else { XCTFail("attacking a paused monster must fail") }
        if case .failure(let e) = GameEngine.autokill(into: &f.state, recordID: f.mB, at: t(300)) {
            XCTAssertEqual(e, .minibossActive)
        } else { XCTFail("autokilling a paused monster must fail") }

        // The miniboss itself is attackable; paused state is untouched throughout.
        let before = f.state.remainingHP(of: f.state.monsterRecord(f.mB)!)
        let mbID = f.state.aliveMiniboss!.id
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: mbID, studentID: f.sB, amount: 4, at: t(300)).get()
        XCTAssertEqual(f.state.damageDealt(toMonster: mbID), 4)
        XCTAssertEqual(f.state.remainingHP(of: f.state.monsterRecord(f.mB)!), before) // frozen

        // Teacher HP edits on a paused monster stay allowed (no spawn risk, undoable).
        _ = try! GameEngine.adjustHP(into: &f.state, recordID: f.mB, delta: -10, at: t(300)).get()
        XCTAssertTrue(GameEngine.undoLast(into: &f.state, teamScope: f.teamB))
    }

    // MARK: - No carry across the miniboss boundary (client default, both ways)

    func testOverkillDoesNotCarryIntoTriggeredMiniboss() {
        var f = makeFixture()
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: f.mA, studentID: f.sA, amount: 10, at: t(100)).get()
        let succ = f.state.aliveRegularRecord(forTeam: f.teamA)!

        // 12 vs the 5-HP successor: capped 5 kills it, the trigger fires, and the
        // leftover 7 is DISCARDED — the miniboss starts clean.
        let result = try! GameEngine.attack(into: &f.state, targetRecordID: succ.id, studentID: f.sA, amount: 12, at: t(200)).get()
        XCTAssertEqual(result.entries.map { $0.amount }, [5])
        XCTAssertEqual(result.defeats.count, 1)
        let miniboss = f.state.aliveMiniboss!
        XCTAssertEqual(f.state.damageDealt(toMonster: miniboss.id), 0)
    }

    func testMinibossDefeatResumesTriggeringTeamWithNoCarryOut() {
        var f = makeTriggeredFixture()
        let mbID = f.state.aliveMiniboss!.id

        // 95 vs the 90-HP miniboss: capped 90 kills it; the leftover 5 is DISCARDED.
        let result = try! GameEngine.attack(into: &f.state, targetRecordID: mbID, studentID: f.sB, amount: 95, at: t(300)).get()
        XCTAssertEqual(result.entries.map { $0.amount }, [90])
        XCTAssertEqual(result.defeats.count, 1)
        XCTAssertNil(f.state.aliveMiniboss)

        // Resume: team A's next monster comes from the lineup AFTER the spent
        // miniboss slot (R1), starting clean; pointer advanced past it (wraps to 0).
        let resumed = f.state.aliveRegularRecord(forTeam: f.teamA)!
        XCTAssertEqual(resumed.templateID, f.tplR1)
        XCTAssertEqual(f.state.damageDealt(toMonster: resumed.id), 0)   // no carry out
        XCTAssertEqual(f.state.teams.first { $0.id == f.teamA }?.nextLineupIndex, 0)

        // Team B's paused battle is exactly where it was, and attackable again.
        XCTAssertEqual(f.state.remainingHP(of: f.state.monsterRecord(f.mB)!), 100)
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: f.mB, studentID: f.sB, amount: 3, at: t(400)).get()
        XCTAssertEqual(f.state.damageDealt(toMonster: f.mB), 3)

        // The defeated miniboss has its OWN past-board slot, crediting the capped 90.
        let pastMB = Leaderboards.pastMiniboss(state: f.state)
        XCTAssertEqual(pastMB.count, 1)
        XCTAssertEqual(pastMB.first?.id, f.sB)
        XCTAssertEqual(pastMB.first?.totalDamage, 90)
        XCTAssertEqual(pastMB.first?.rank, 1)
    }

    // MARK: - Undo across the miniboss boundaries

    func testUndoTriggerKillRemovesMinibossAndLiftsPause() {
        var f = makeTriggeredFixture()
        XCTAssertNotNil(f.state.aliveMiniboss)

        XCTAssertTrue(GameEngine.undoLast(into: &f.state)) // global: the trigger kill

        XCTAssertNil(f.state.aliveMiniboss)                        // miniboss un-spawned
        XCTAssertFalse(f.state.isSpent(slot: f.slotMB))            // slot un-spent
        let revived = f.state.aliveRegularRecord(forTeam: f.teamA)!
        XCTAssertEqual(revived.templateID, f.tplR2)                // the R2 successor is back
        XCTAssertEqual(f.state.remainingHP(of: revived), 5)
        // Pause lifted: team B is attackable again.
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: f.mB, studentID: f.sB, amount: 2, at: t(300)).get()
    }

    func testUndoMinibossKillRestoresPauseAndPointer() {
        var f = makeTriggeredFixture()
        let mbID = f.state.aliveMiniboss!.id
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: mbID, studentID: f.sB, amount: 90, at: t(300)).get()
        XCTAssertNil(f.state.aliveMiniboss)
        XCTAssertEqual(f.state.teams.first { $0.id == f.teamA }?.nextLineupIndex, 0) // advanced on resume

        XCTAssertTrue(GameEngine.undoLast(into: &f.state)) // global: the miniboss kill

        // Back mid-pause: miniboss alive at full HP, resume-spawn gone, pointer restored.
        XCTAssertNotNil(f.state.aliveMiniboss)
        XCTAssertEqual(f.state.remainingHP(of: f.state.aliveMiniboss!), 90)
        XCTAssertNil(f.state.aliveRegularRecord(forTeam: f.teamA))
        XCTAssertEqual(f.state.teams.first { $0.id == f.teamA }?.nextLineupIndex, 1)
        if case .failure(let e) = GameEngine.attack(into: &f.state, targetRecordID: f.mB, studentID: f.sB, amount: 1, at: t(400)) {
            XCTAssertEqual(e, .minibossActive)                     // paused again
        } else { XCTFail("pause must be restored by undoing the miniboss kill") }
    }

    // MARK: - Lineup editing during the pause (intended feature)

    func testLineupEditDuringPauseShapesTheResume() {
        var f = makeTriggeredFixture()

        // Teacher swaps the post-miniboss slot from R1 to a new R2 slot, mid-pause.
        let newSlot = LineupSlot(templateID: f.tplR2)
        _ = try! GameEngine.setLineup(into: &f.state,
                                      slots: [f.slotR2, f.slotMB, newSlot], at: t(250)).get()

        let mbID = f.state.aliveMiniboss!.id
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: mbID, studentID: f.sB, amount: 90, at: t(300)).get()

        // Resume follows the EDITED lineup: team A faces R2, not the original R1.
        let resumed = f.state.aliveRegularRecord(forTeam: f.teamA)!
        XCTAssertEqual(resumed.templateID, f.tplR2)
        XCTAssertEqual(resumed.lineupSlotID, newSlot.id)
    }

    /// Editing a PAUSED team's older attack during a miniboss must refuse cleanly (the
    /// re-apply would hit the pause gate after the undo — edit would become delete),
    /// while editing the TRIGGER attack itself stays legal (its undo removes the miniboss).
    func testEditDuringMinibossRefusesPausedTargetsButAllowsTheTrigger() {
        var f = makeFixture()
        // Team B logs a normal hit first, then team A triggers the miniboss.
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: f.mB, studentID: f.sB, amount: 7, at: t(50)).get()
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: f.mA, studentID: f.sA, amount: 10, at: t(100)).get()
        let succ = f.state.aliveRegularRecord(forTeam: f.teamA)!
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: succ.id, studentID: f.sA, amount: 5, at: t(200)).get()
        XCTAssertNotNil(f.state.aliveMiniboss)

        // Team B's last attack is on a paused monster → edit must refuse, state untouched.
        let before = f.state
        if case .failure(let e) = GameEngine.editMostRecentAttack(into: &f.state, teamScope: f.teamB, newAmount: 9) {
            XCTAssertEqual(e, .minibossActive)
        } else { XCTFail("editing a paused team's entry mid-miniboss must refuse") }
        XCTAssertEqual(f.state, before)

        // Editing the TRIGGER attack (team A's most recent) is legal: un-triggers, then
        // re-applies — 5 was an exact kill, so a new amount of 2 leaves no kill/trigger.
        let edited = try! GameEngine.editMostRecentAttack(into: &f.state, teamScope: f.teamA, newAmount: 2).get()
        XCTAssertFalse(edited.killed)
        XCTAssertNil(f.state.aliveMiniboss)                       // trigger reversed
        XCTAssertEqual(f.state.remainingHP(of: f.state.aliveRegularRecord(forTeam: f.teamA)!), 3) // 5-HP succ, 2 dealt
        XCTAssertEqual(f.state.damageDealt(toMonster: f.mB), 7)   // team B untouched throughout
    }

    func testSetLineupValidatesAndUndoes() {
        var f = makeFixture()
        // Unknown template rejected.
        if case .failure(let e) = GameEngine.setLineup(into: &f.state,
                                                       slots: [LineupSlot(templateID: UUID())], at: t(50)) {
            XCTAssertEqual(e, .templateNotFound)
        } else { XCTFail("unknown template must be rejected") }

        // Valid edit applies; team-scoped undo can NOT reach it (global action)…
        let original = f.state.lineup
        _ = try! GameEngine.setLineup(into: &f.state, slots: [f.slotR1], at: t(60)).get()
        XCTAssertEqual(f.state.lineup, [f.slotR1])
        XCTAssertFalse(GameEngine.undoLast(into: &f.state, teamScope: f.teamA))
        // …but global undo restores the previous lineup.
        XCTAssertTrue(GameEngine.undoLast(into: &f.state))
        XCTAssertEqual(f.state.lineup, original)
    }
}
