//
//  GameEngine.swift — the pure game logic: spawn, attack/defeat, the three backdoor
//  controls, and the unified undo. Every operation is a pure transform of `AppState`
//  (validate → mutate → record the action), so it is fully unit-testable with no UI
//  and no persistence. The (later) GameStore wraps these and adds atomic save + publish.
//
//  Design decisions locked with the client:
//    • Overkill damage is DISCARDED — the killing student is credited their full hit
//      on the dying monster; the successor spawns fresh at full HP.
//    • Teacher admin actions (HP adjust, autokill, miniboss spawn) join the SAME
//      ordered action history as attacks, so there is one unified, scoped Undo.
//    • Attacks target an explicit monster record id, so the eventual miniboss
//      targeting UX (coexist vs pause) is NOT baked in here — see the MINIBOSS note.
//

import Foundation

public enum EngineError: Error, Equatable {
    case studentNotFound
    case monsterNotFound
    case monsterAlreadyDefeated
    case negativeAmount
    case invalidKillTarget
    case teamNotFound
    case templateNotFound
    case teamHasActiveMonster
}

public struct AttackResult: Equatable {
    public let entry: CombatLogEntry
    public let killed: Bool
    public let outcome: DefeatOutcome?
}

public enum GameEngine {

    // MARK: - Spawning the first monster of a battle

    /// Spawns a team's first regular monster (battle setup; not itself an undoable
    /// action — successor spawns happen via defeats, which ARE undoable).
    @discardableResult
    public static func spawnInitialMonster(into state: inout AppState,
                                           teamID: UUID,
                                           templateID: UUID,
                                           at: Date,
                                           killTargetWeeks: Int? = nil) -> Result<MonsterRecord, EngineError> {
        guard state.teams.contains(where: { $0.id == teamID }) else { return .failure(.teamNotFound) }
        guard state.monsterCatalog.contains(where: { $0.id == templateID }) else { return .failure(.templateNotFound) }
        guard state.aliveRegularRecord(forTeam: teamID) == nil else { return .failure(.teamHasActiveMonster) }

        let record = MonsterRecord(
            templateID: templateID,
            kind: .regular,
            teamID: teamID,
            spawnedAt: at,
            spawnSequence: state.nextSpawnSequence,
            spawnAverages: teamSpawnAverages(teamID: teamID, state: state, at: at),
            killTargetWeeks: killTargetWeeks ?? state.settings.defaultKillTargetWeeks
        )
        state.ledger.append(record)
        return .success(record)
    }

    // MARK: - Attack

    /// Logs an attack against an explicit monster instance. If it brings cumulative
    /// damage to or past the monster's effective HP, the monster is defeated, its
    /// final board is frozen, and a successor spawns — all reversible by undoing this
    /// one action. Overkill is discarded (full hit credited; successor starts fresh).
    @discardableResult
    public static func attack(into state: inout AppState,
                              targetRecordID: UUID,
                              studentID: UUID,
                              amount: Int,
                              at: Date) -> Result<AttackResult, EngineError> {
        guard amount >= 0 else { return .failure(.negativeAmount) }
        guard state.student(studentID) != nil else { return .failure(.studentNotFound) }
        guard let target = state.monsterRecord(targetRecordID) else { return .failure(.monsterNotFound) }
        guard target.isAlive else { return .failure(.monsterAlreadyDefeated) }

        // 1. Append the attack entry (sequence is monotonic and never reused).
        let entry = CombatLogEntry(sequence: state.combatLog.nextSequence,
                                   studentID: studentID,
                                   monsterRecordID: targetRecordID,
                                   amount: amount,
                                   timestamp: at,
                                   origin: .live)
        state.combatLog.entries.append(entry)
        state.combatLog.nextSequence += 1

        // 2. Kill check — overflow discarded.
        var outcome: DefeatOutcome? = nil
        if state.damageDealt(toMonster: targetRecordID) >= state.effectiveHP(of: target) {
            outcome = resolveDefeat(into: &state, defeatedRecordID: targetRecordID,
                                    reason: .finalBlow, killingEntryID: entry.id, at: at)
        }

        state.actions.append(.attack(AttackAction(entry: entry, causedDefeat: outcome)))
        return .success(AttackResult(entry: entry, killed: outcome != nil, outcome: outcome))
    }

    // MARK: - Backdoor controls (teacher admin)

    /// #1 Add/subtract a monster's HP WITHOUT a combat-log entry. Stored as a signed
    /// offset so it survives a kill-target recompute.
    @discardableResult
    public static func adjustHP(into state: inout AppState,
                                recordID: UUID,
                                delta: Int,
                                at: Date) -> Result<Void, EngineError> {
        guard let idx = state.ledger.firstIndex(where: { $0.id == recordID }) else { return .failure(.monsterNotFound) }
        guard state.ledger[idx].isAlive else { return .failure(.monsterAlreadyDefeated) } // only the current monster
        state.ledger[idx].backdoorHPDelta += delta
        state.actions.append(.adjustHP(HPAdjustAction(monsterRecordID: recordID, delta: delta, at: at)))
        return .success(())
    }

    /// #2 Change the kill-target weeks mid-battle; HP recomputes automatically from the
    /// frozen spawn averages. (Note: this does NOT auto-defeat a monster whose new HP
    /// falls at/below damage already dealt — `remainingHP` simply clamps to 0 and the
    /// teacher finishes it with the next attack or autokill. Pending client confirm.)
    @discardableResult
    public static func setKillTarget(into state: inout AppState,
                                     recordID: UUID,
                                     weeks: Int,
                                     at: Date) -> Result<Void, EngineError> {
        guard weeks > 0 else { return .failure(.invalidKillTarget) }
        guard let idx = state.ledger.firstIndex(where: { $0.id == recordID }) else { return .failure(.monsterNotFound) }
        guard state.ledger[idx].isAlive else { return .failure(.monsterAlreadyDefeated) } // only the current monster
        let previous = state.ledger[idx].killTargetWeeks
        state.ledger[idx].killTargetWeeks = weeks
        state.actions.append(.setKillTarget(KillTargetAction(monsterRecordID: recordID,
                                                             previousWeeks: previous, newWeeks: weeks, at: at)))
        return .success(())
    }

    /// #3 Autokill: end the current monster now (no final blow). Freezes the board and
    /// spawns the successor exactly like a normal kill, so undo reverses it identically.
    @discardableResult
    public static func autokill(into state: inout AppState,
                                recordID: UUID,
                                at: Date) -> Result<DefeatOutcome, EngineError> {
        guard let record = state.monsterRecord(recordID) else { return .failure(.monsterNotFound) }
        guard record.isAlive else { return .failure(.monsterAlreadyDefeated) }
        let outcome = resolveDefeat(into: &state, defeatedRecordID: recordID,
                                    reason: .autokill, killingEntryID: nil, at: at)
        state.actions.append(.autokill(AutokillAction(outcome: outcome, at: at)))
        return .success(outcome)
    }

    // MARK: - Undo (unified, optionally team-scoped)

    /// Reverses the most recent action. With `teamScope`, reverses the most recent
    /// action affecting that team (the teacher's mental model under concurrent team
    /// battles); with nil, the globally most recent action. Returns false if nothing
    /// was undone.
    @discardableResult
    public static func undoLast(into state: inout AppState, teamScope: UUID? = nil) -> Bool {
        guard let i = lastActionIndex(forTeam: teamScope, state: state) else { return false }

        switch state.actions[i] {
        case .attack(let a):
            removeEntry(a.entry.id, &state)
            if let outcome = a.causedDefeat { reverseDefeat(outcome, &state) }
        case .adjustHP(let a):
            if let idx = state.ledger.firstIndex(where: { $0.id == a.monsterRecordID }) {
                state.ledger[idx].backdoorHPDelta -= a.delta
            }
        case .setKillTarget(let a):
            if let idx = state.ledger.firstIndex(where: { $0.id == a.monsterRecordID }) {
                state.ledger[idx].killTargetWeeks = a.previousWeeks
            }
        case .autokill(let a):
            reverseDefeat(a.outcome, &state)
        case .spawnMiniboss(let a):
            removeRecordIfEmpty(a.spawnedRecord.id, &state)
        }

        state.actions.remove(at: i)
        return true
    }

    // MARK: - Shared internals

    /// Mark a monster defeated, freeze its top-3 board, and (for a regular monster)
    /// spawn the successor. Used by both a final-blow kill and an autokill.
    private static func resolveDefeat(into state: inout AppState,
                                      defeatedRecordID: UUID,
                                      reason: DefeatOutcome.Reason,
                                      killingEntryID: UUID?,
                                      at: Date) -> DefeatOutcome {
        // Freeze the final standings (top 3, ties at the cutoff included) from the log
        // as it stands now (after the killing entry, if any, was appended).
        let frozen = freezeTopThree(recordID: defeatedRecordID, state: state)

        if let idx = state.ledger.firstIndex(where: { $0.id == defeatedRecordID }) {
            state.ledger[idx].defeatedAt = at
            state.ledger[idx].defeatedByEntryID = killingEntryID
            state.ledger[idx].finalLeaderboard = frozen
        }

        // Spawn the successor for a regular monster. MINIBOSS: successor/lifecycle is
        // intentionally NOT handled here — pending client input on the miniboss flow.
        var spawned: MonsterRecord? = nil
        if let defeated = state.monsterRecord(defeatedRecordID),
           defeated.kind == .regular, let teamID = defeated.teamID {
            let templateID = nextRegularTemplate(after: defeated.templateID, in: state) ?? defeated.templateID
            let successor = MonsterRecord(
                templateID: templateID,
                kind: .regular,
                teamID: teamID,
                spawnedAt: at,
                spawnSequence: state.nextSpawnSequence,
                spawnedByEntryID: killingEntryID,
                spawnAverages: teamSpawnAverages(teamID: teamID, state: state, at: at),
                // Inherit the defeated monster's kill target for battle continuity.
                killTargetWeeks: defeated.killTargetWeeks
            )
            state.ledger.append(successor)
            spawned = successor
        }

        return DefeatOutcome(defeatedRecordID: defeatedRecordID,
                             frozenFinalLeaderboard: frozen,
                             spawnedRecord: spawned,
                             reason: reason)
    }

    /// Reverse a defeat: drop the spawned successor (guaranteed entry-free under the
    /// scoped-LIFO undo order) and revive the defeated record.
    private static func reverseDefeat(_ outcome: DefeatOutcome, _ state: inout AppState) {
        if let successor = outcome.spawnedRecord {
            removeRecordIfEmpty(successor.id, &state)
        }
        if let idx = state.ledger.firstIndex(where: { $0.id == outcome.defeatedRecordID }) {
            state.ledger[idx].defeatedAt = nil
            state.ledger[idx].defeatedByEntryID = nil
            state.ledger[idx].finalLeaderboard = nil
        }
    }

    private static func freezeTopThree(recordID: UUID, state: AppState) -> [LeaderboardSnapshotRow] {
        Leaderboards.currentMonster(recordID: recordID, state: state)
            .filter { $0.rank <= 3 }
            .map { LeaderboardSnapshotRow(id: $0.id, displayName: $0.displayName,
                                          totalDamage: $0.totalDamage, rank: $0.rank) }
    }

    private static func nextRegularTemplate(after current: UUID, in state: AppState) -> UUID? {
        let regulars = state.monsterCatalog.filter { $0.kind == .regular }
        guard !regulars.isEmpty else { return nil }
        guard let idx = regulars.firstIndex(where: { $0.id == current }) else { return regulars[0].id }
        return regulars[(idx + 1) % regulars.count].id
    }

    private static func teamSpawnAverages(teamID: UUID, state: AppState, at: Date) -> [StudentAverage] {
        let calendar = state.settings.resolvedCalendar
        return state.activeStudents
            .filter { $0.teamID == teamID }
            .map { StudentAverage(studentID: $0.id,
                                  average: PracticeMath.dailyAverage(forStudent: $0.id,
                                                                     entries: state.combatLog.entries,
                                                                     now: at, calendar: calendar)) }
    }

    private static func removeEntry(_ entryID: UUID, _ state: inout AppState) {
        state.combatLog.entries.removeAll { $0.id == entryID }
        // nextSequence is intentionally NOT decremented — sequence numbers are never reused.
    }

    /// Removes a ledger record only if no combat entries reference it. Under scoped
    /// LIFO undo a kill-spawned successor always has zero entries when reversed; the
    /// guard is defensive so we never silently orphan real damage.
    private static func removeRecordIfEmpty(_ recordID: UUID, _ state: inout AppState) {
        guard !state.combatLog.entries.contains(where: { $0.monsterRecordID == recordID }) else { return }
        state.ledger.removeAll { $0.id == recordID }
    }

    /// Index of the most recent action, optionally restricted to a team's timeline.
    private static func lastActionIndex(forTeam teamID: UUID?, state: AppState) -> Int? {
        guard let teamID = teamID else {
            return state.actions.isEmpty ? nil : state.actions.count - 1
        }
        for i in state.actions.indices.reversed() {
            if let recordID = state.actions[i].monsterRecordID,
               state.monsterRecord(recordID)?.teamID == teamID {
                return i
            }
        }
        return nil
    }
}
