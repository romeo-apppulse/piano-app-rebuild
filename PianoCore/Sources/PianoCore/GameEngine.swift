//
//  GameEngine.swift — the pure game logic: spawn, attack/defeat, the three backdoor
//  controls, and the unified undo. Every operation is a pure transform of `AppState`
//  (validate → mutate → record the action), so it is fully unit-testable with no UI
//  and no persistence. The (later) GameStore wraps these and adds atomic save + publish.
//
//  Design decisions locked with the client:
//    • Overkill damage CARRIES OVER: when an attack exceeds the monster's remaining
//      HP, a capped killing entry lands on the dying monster and the leftover rolls
//      onto the freshly spawned successor as its own entry — chaining if the leftover
//      kills the successor too. One AttackAction records the whole chain, so a single
//      undo reverses ALL of it (entries, spawns, defeats, lock-ins) atomically.
//    • Only the MOST RECENT combat-log entry is editable/deletable; older entries are
//      locked. Deleting the most recent entry IS undo (same operation); editing is
//      undo + re-apply, so kill/carryover consequences always recompute exactly.
//    • Teacher admin actions (HP adjust, autokill, miniboss spawn) join the SAME
//      ordered action history as attacks, so there is one unified, scoped Undo.
//    • Attacks target an explicit monster record id, so the eventual miniboss
//      targeting UX is NOT baked in here — see the MINIBOSS note in resolveDefeat.
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
    /// The most recent action in scope is not an attack entry (or there is none), so
    /// there is nothing that may be edited/deleted under the most-recent-only policy.
    case noEditableEntry
}

public struct AttackResult: Equatable {
    /// Every entry the attack created (first = on the original target; the rest are
    /// carryover on successors).
    public let entries: [CombatLogEntry]
    /// Every defeat the attack caused, in order (empty for a plain hit).
    public let defeats: [DefeatOutcome]

    public var killed: Bool { !defeats.isEmpty }
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

    // MARK: - Attack (with overkill carryover)

    /// Logs an attack against an explicit monster instance.
    ///
    /// If the amount meets or exceeds the target's remaining HP, the target dies: a
    /// capped entry (exactly the remaining HP) lands on it, its top-3 board freezes,
    /// a successor spawns, and the LEFTOVER carries onto the successor as a separate
    /// entry — repeating if the leftover kills the successor too. The whole chain is
    /// one action; one undo reverses all of it.
    ///
    /// Leftover with no successor to receive it (nothing respawned) is discarded.
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

        var entries: [CombatLogEntry] = []
        var defeats: [DefeatOutcome] = []
        var current = target
        var pending = amount

        while true {
            let remaining = state.remainingHP(of: current)

            if pending < remaining {
                // Plain hit — no kill, chain ends.
                entries.append(state.combatLog.appendEntry(studentID: studentID,
                                                           monsterRecordID: current.id,
                                                           amount: pending,
                                                           timestamp: at))
                break
            }

            // Kill: land exactly the remaining HP on the dying monster; the rest carries.
            let killingEntry = state.combatLog.appendEntry(studentID: studentID,
                                                           monsterRecordID: current.id,
                                                           amount: remaining,
                                                           timestamp: at)
            entries.append(killingEntry)
            pending -= remaining

            let outcome = resolveDefeat(into: &state, defeatedRecordID: current.id,
                                        reason: .finalBlow, killingEntryID: killingEntry.id, at: at)
            defeats.append(outcome)

            // Carry the leftover onto the successor, or stop. The remaining-HP > 0
            // check is a defensive guard against a zero-HP successor (only possible
            // with a pathological minimumMonsterHP of 0) looping forever.
            guard pending > 0,
                  let successor = outcome.spawnedRecord,
                  state.remainingHP(of: successor) > 0 else { break }
            current = successor
        }

        state.actions.append(.attack(AttackAction(entries: entries, defeats: defeats)))
        return .success(AttackResult(entries: entries, defeats: defeats))
    }

    // MARK: - Most-recent-entry policy (edit / delete)

    /// Edits the amount of the MOST RECENT attack in scope (the only editable entry
    /// under the client's lock-older-entries policy). Implemented as undo + re-apply
    /// against the original target at the original timestamp, so any kill/carryover
    /// consequences of the old amount are fully reversed and the new amount's
    /// consequences recompute exactly.
    @discardableResult
    public static func editMostRecentAttack(into state: inout AppState,
                                            teamScope: UUID? = nil,
                                            newAmount: Int) -> Result<AttackResult, EngineError> {
        guard newAmount >= 0 else { return .failure(.negativeAmount) }
        guard let i = lastActionIndex(forTeam: teamScope, state: state),
              case .attack(let a) = state.actions[i],
              let original = a.entries.first else { return .failure(.noEditableEntry) }

        _ = undoLast(into: &state, teamScope: teamScope)
        return attack(into: &state,
                      targetRecordID: original.monsterRecordID,
                      studentID: original.studentID,
                      amount: newAmount,
                      at: original.timestamp)
    }

    /// Deletes the MOST RECENT attack entry in scope. By design this is the SAME
    /// operation as undoing the most recent attack action — there is exactly one
    /// removal path, so "delete" and "undo" can never disagree. Fails if the most
    /// recent action in scope is a teacher admin action (undo that explicitly).
    @discardableResult
    public static func deleteMostRecentEntry(into state: inout AppState,
                                             teamScope: UUID? = nil) -> Result<Void, EngineError> {
        guard let i = lastActionIndex(forTeam: teamScope, state: state),
              case .attack = state.actions[i] else { return .failure(.noEditableEntry) }
        _ = undoLast(into: &state, teamScope: teamScope)
        return .success(())
    }

    // MARK: - Backdoor controls (teacher admin)

    /// #1 Add/subtract a monster's HP WITHOUT a combat-log entry. Stored as a signed
    /// offset so it survives a kill-target recompute. Only the current (alive) monster.
    @discardableResult
    public static func adjustHP(into state: inout AppState,
                                recordID: UUID,
                                delta: Int,
                                at: Date) -> Result<Void, EngineError> {
        guard let idx = state.ledger.firstIndex(where: { $0.id == recordID }) else { return .failure(.monsterNotFound) }
        guard state.ledger[idx].isAlive else { return .failure(.monsterAlreadyDefeated) }
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
        guard state.ledger[idx].isAlive else { return .failure(.monsterAlreadyDefeated) }
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
    ///
    /// Undoing an attack reverses its ENTIRE chain: every entry it created (including
    /// carryover on successors) is removed, and every defeat it caused is reverted in
    /// reverse order — successors un-spawned, defeated monsters revived at their
    /// pre-kill damage, frozen leaderboard lock-ins cleared.
    @discardableResult
    public static func undoLast(into state: inout AppState, teamScope: UUID? = nil) -> Bool {
        guard let i = lastActionIndex(forTeam: teamScope, state: state) else { return false }

        switch state.actions[i] {
        case .attack(let a):
            state.combatLog.removeEntries(withIDs: Set(a.entries.map { $0.id }))
            for outcome in a.defeats.reversed() { reverseDefeat(outcome, &state) }
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
        // Freeze the final standings (placement <= 3, ties included) from the log as
        // it stands now (after the capped killing entry, if any, was appended — so the
        // dying monster is credited exactly the damage that killed it, not the carry).
        let frozen = freezeTopThree(recordID: defeatedRecordID, state: state)

        if let idx = state.ledger.firstIndex(where: { $0.id == defeatedRecordID }) {
            state.ledger[idx].defeatedAt = at
            state.ledger[idx].defeatedByEntryID = killingEntryID
            state.ledger[idx].finalLeaderboard = frozen
        }

        // Spawn the successor for a regular monster. MINIBOSS: successor/lifecycle is
        // intentionally NOT handled here — the client-approved suspend/resume design
        // will land here once reviewed.
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

    /// Reverse a defeat: drop the spawned successor (entry-free by the time this runs,
    /// because undo removes the whole attack chain's entries first) and revive the
    /// defeated record.
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

    /// Removes a ledger record only if no combat entries reference it. Under LIFO undo
    /// a spawned successor is always entry-free when reversed (the chain's entries are
    /// removed first); the guard is defensive so we never silently orphan real damage.
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
