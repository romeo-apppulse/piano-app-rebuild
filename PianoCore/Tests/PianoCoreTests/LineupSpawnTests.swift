//
//  LineupSpawnTests.swift — the INITIAL monster now comes from the lineup (not an
//  off-lineup Backdoor spawn), so the lineup pointer and the battle stay in lockstep.
//  This closes the client's bug: with a miniboss in the lineup, defeating the first
//  monster did not auto-trigger the miniboss, because the hand-started first monster
//  sat outside the lineup and never advanced the pointer.
//
//  Fixture design mirrors MinibossFlowTests: students are UNASSIGNED so team
//  spawn-averages are empty and every regular spawns at the minimumMonsterHP floor (5) —
//  deterministic, so an exact 5-damage hit is always a kill.
//

import XCTest
@testable import PianoCore

final class LineupSpawnTests: XCTestCase {

    private func t(_ s: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }

    private struct Fixture {
        var state: AppState
        let teamA: UUID, teamB: UUID
        let sA: UUID
        let tplR1: UUID, tplR2: UUID, tplMB: UUID
    }

    /// Two teams (no members), one unassigned student, empty ledger (no live monsters),
    /// and a catalog of R1 / R2 / miniboss. The lineup is set per-test.
    private func makeFixture(lineup: [LineupSlot]) -> Fixture {
        let teamA = UUID(); let teamB = UUID()
        let sA = UUID()
        let tplR1 = UUID(); let tplR2 = UUID(); let tplMB = UUID()

        let state = AppState(
            students: [Student(id: sA, name: "A", teamID: nil, createdAt: t(0))],
            teams: [Team(id: teamA, name: "Reds"), Team(id: teamB, name: "Blues")],
            monsterCatalog: [
                MonsterTemplate(id: tplR1, name: "R1", kind: .regular),
                MonsterTemplate(id: tplR2, name: "R2", kind: .regular),
                MonsterTemplate(id: tplMB, name: "Boss", kind: .miniboss),
            ],
            lineup: lineup,
            ledger: [],
            settings: GameSettings(minimumMonsterHP: 5)
        )
        return Fixture(state: state, teamA: teamA, teamB: teamB, sA: sA,
                       tplR1: tplR1, tplR2: tplR2, tplMB: tplMB)
    }

    // MARK: - spawnFromLineup

    func testSpawnFromLineupSpawnsFirstRegularAndAdvancesPointer() {
        var f = makeFixture(lineup: [])
        let s1 = LineupSlot(templateID: f.tplR1)
        let s2 = LineupSlot(templateID: f.tplR2)
        f.state.lineup = [s1, s2]

        let spawned = try! GameEngine.spawnFromLineup(into: &f.state, teamID: f.teamA, at: t(100)).get()
        XCTAssertEqual(spawned?.templateID, f.tplR1)
        XCTAssertEqual(spawned?.lineupSlotID, s1.id)                 // tied to the slot
        XCTAssertEqual(f.state.effectiveHP(of: spawned!), 5)        // empty team → floor
        XCTAssertEqual(f.state.teams.first { $0.id == f.teamA }?.nextLineupIndex, 1)
    }

    func testSpawnFromLineupSkipsALeadingMinibossToTheFirstRegular() {
        var f = makeFixture(lineup: [])
        let sMB = LineupSlot(templateID: f.tplMB)
        let sR1 = LineupSlot(templateID: f.tplR1)
        f.state.lineup = [sMB, sR1]

        // A miniboss can't be an initial spawn (it needs a triggering defeat), so the
        // first regular is used and the pointer advances past it (wraps to 0).
        let spawned = try! GameEngine.spawnFromLineup(into: &f.state, teamID: f.teamA, at: t(100)).get()
        XCTAssertEqual(spawned?.templateID, f.tplR1)
        XCTAssertEqual(spawned?.lineupSlotID, sR1.id)
        XCTAssertNil(f.state.aliveMiniboss)                          // NOT triggered
        XCTAssertEqual(f.state.teams.first { $0.id == f.teamA }?.nextLineupIndex, 0)
    }

    func testSpawnFromLineupIsNoOpWhenTeamAlreadyFighting() {
        var f = makeFixture(lineup: [])
        f.state.lineup = [LineupSlot(templateID: f.tplR1)]
        _ = try! GameEngine.spawnFromLineup(into: &f.state, teamID: f.teamA, at: t(100)).get()

        // Second call must not double-spawn.
        let again = try! GameEngine.spawnFromLineup(into: &f.state, teamID: f.teamA, at: t(200)).get()
        XCTAssertNil(again)
        XCTAssertEqual(f.state.ledger.filter { $0.teamID == f.teamA }.count, 1)
    }

    func testSpawnFromLineupIsNoOpWithEmptyLineup() {
        var f = makeFixture(lineup: [])
        let spawned = try! GameEngine.spawnFromLineup(into: &f.state, teamID: f.teamA, at: t(100)).get()
        XCTAssertNil(spawned)
        XCTAssertTrue(f.state.ledger.isEmpty)
    }

    // MARK: - startIdleTeamsFromLineup

    func testStartIdleTeamsStartsEveryTeamAtTheBeginning() {
        var f = makeFixture(lineup: [])
        let s1 = LineupSlot(templateID: f.tplR1)
        f.state.lineup = [s1, LineupSlot(templateID: f.tplR2)]

        let spawned = GameEngine.startIdleTeamsFromLineup(into: &f.state, at: t(100))
        XCTAssertEqual(spawned.count, 2)                             // both teams started
        XCTAssertEqual(f.state.aliveRegularRecord(forTeam: f.teamA)?.templateID, f.tplR1)
        XCTAssertEqual(f.state.aliveRegularRecord(forTeam: f.teamB)?.templateID, f.tplR1)
        XCTAssertEqual(f.state.teams.first { $0.id == f.teamA }?.nextLineupIndex, 1)
        XCTAssertEqual(f.state.teams.first { $0.id == f.teamB }?.nextLineupIndex, 1)
    }

    func testStartIdleTeamsLeavesAFightingTeamUntouched() {
        var f = makeFixture(lineup: [])
        f.state.lineup = [LineupSlot(templateID: f.tplR1), LineupSlot(templateID: f.tplR2)]

        // Team A is already fighting R2 with its pointer parked at 1.
        if let idx = f.state.teams.firstIndex(where: { $0.id == f.teamA }) {
            f.state.teams[idx].nextLineupIndex = 1
        }
        f.state.ledger.append(MonsterRecord(templateID: f.tplR2, kind: .regular, teamID: f.teamA,
                                            spawnedAt: t(0), spawnSequence: 0, killTargetWeeks: 3,
                                            legacyFixedHP: 50))

        _ = GameEngine.startIdleTeamsFromLineup(into: &f.state, at: t(100))
        // Team A untouched (still on R2, pointer still 1); team B started fresh at R1.
        XCTAssertEqual(f.state.aliveRegularRecord(forTeam: f.teamA)?.templateID, f.tplR2)
        XCTAssertEqual(f.state.teams.first { $0.id == f.teamA }?.nextLineupIndex, 1)
        XCTAssertEqual(f.state.aliveRegularRecord(forTeam: f.teamB)?.templateID, f.tplR1)
    }

    func testStartIdleTeamsIsNoOpDuringAMiniboss() {
        var f = makeFixture(lineup: [])
        f.state.lineup = [LineupSlot(templateID: f.tplR1)]
        // A live miniboss means all battles are paused.
        f.state.ledger.append(MonsterRecord(templateID: f.tplMB, kind: .miniboss, teamID: nil,
                                            spawnedAt: t(0), spawnSequence: 0, killTargetWeeks: 6,
                                            legacyFixedHP: 100, triggeredByTeamID: f.teamA))
        let spawned = GameEngine.startIdleTeamsFromLineup(into: &f.state, at: t(100))
        XCTAssertTrue(spawned.isEmpty)
        XCTAssertNil(f.state.aliveRegularRecord(forTeam: f.teamA))
    }

    // MARK: - The end-to-end bug: lineup-started monster → defeat → miniboss triggers

    func testLineupStartedMonsterDefeatAutoTriggersTheMiniboss() {
        var f = makeFixture(lineup: [])
        let sR1 = LineupSlot(templateID: f.tplR1)
        let sMB = LineupSlot(templateID: f.tplMB)
        f.state.lineup = [sR1, sMB]

        // Start team A from the lineup (this is what saving the lineup now does).
        _ = GameEngine.startIdleTeamsFromLineup(into: &f.state, at: t(50))
        let r1 = f.state.aliveRegularRecord(forTeam: f.teamA)!
        XCTAssertEqual(r1.templateID, f.tplR1)
        XCTAssertEqual(f.state.teams.first { $0.id == f.teamA }?.nextLineupIndex, 1)  // now points at the miniboss

        // Defeat R1 (5 HP). Its next lineup slot is the miniboss → it must auto-trigger.
        _ = try! GameEngine.attack(into: &f.state, targetRecordID: r1.id, studentID: f.sA, amount: 5, at: t(100)).get()

        let miniboss = f.state.aliveMiniboss
        XCTAssertNotNil(miniboss, "defeating the monster before a miniboss slot must trigger the miniboss")
        XCTAssertEqual(miniboss?.templateID, f.tplMB)
        XCTAssertEqual(miniboss?.triggeredByTeamID, f.teamA)
        XCTAssertTrue(f.state.isSpent(slot: sMB))
    }
}
