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
//    • Teacher admin actions (HP adjust, autokill, lineup edits) join the SAME
//      ordered action history as attacks, so there is one unified, scoped Undo.
//    • MINIBOSS (client-approved model): minibosses sit in the shared lineup. The
//      first team to reach one triggers it for EVERYONE (auto, not manual). While a
//      miniboss is alive it is the only legal attack target — that validation gate IS
//      the pause; paused battles are preserved automatically because all battle state
//      derives from the log. On the miniboss's defeat the triggering team's next
//      regular monster spawns from the (possibly teacher-edited) lineup and everyone
//      else simply becomes attackable again. Overkill does NOT cross the miniboss
//      boundary in either direction (client default): no carry into a triggered
//      miniboss, no carry out of a defeated one.
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
    /// A miniboss battle is in progress: it is the only legal target for attacks and
    /// autokill until it is defeated (all team battles are paused).
    case minibossActive
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

    // MARK: - Spawning from the lineup (keeps lineup ↔ battle in lockstep)

    /// Spawns a team's monster FROM its lineup position: the next REGULAR slot at or
    /// after the team's pointer (miniboss slots are skipped — a miniboss only enters via
    /// a triggering defeat, never as an initial spawn). Crucially, this sets the record's
    /// `lineupSlotID` and advances `nextLineupIndex`, so the very first monster of a
    /// battle participates in the lineup exactly like every later successor does. Without
    /// this, an initial monster started from Backdoor sat outside the lineup and the
    /// pointer never moved, so the configured lineup (and its miniboss) never lined up
    /// with the battles actually happening.
    ///
    /// Returns `.success(nil)` when there is nothing to do: the team already has a live
    /// regular monster, the lineup is empty, or the lineup holds no spawnable regular
    /// slot. Battle setup — not an undoable action (consistent with `spawnInitialMonster`).
    @discardableResult
    public static func spawnFromLineup(into state: inout AppState,
                                       teamID: UUID,
                                       at: Date) -> Result<MonsterRecord?, EngineError> {
        guard let teamIdx = state.teams.firstIndex(where: { $0.id == teamID }) else { return .failure(.teamNotFound) }
        guard state.aliveMiniboss == nil else { return .success(nil) }   // battles are paused under a miniboss
        guard state.aliveRegularRecord(forTeam: teamID) == nil else { return .success(nil) }
        guard !state.lineup.isEmpty else { return .success(nil) }

        let count = state.lineup.count
        let rawPointer = state.teams[teamIdx].nextLineupIndex
        var idx = ((rawPointer % count) + count) % count   // safe modulo (edits can shrink the lineup)

        for _ in 0..<count {
            let slot = state.lineup[idx]
            if state.monsterCatalog.first(where: { $0.id == slot.templateID })?.kind == .regular {
                let record = MonsterRecord(
                    templateID: slot.templateID,
                    kind: .regular,
                    teamID: teamID,
                    spawnedAt: at,
                    spawnSequence: state.nextSpawnSequence,
                    spawnAverages: teamSpawnAverages(teamID: teamID, state: state, at: at),
                    killTargetWeeks: state.settings.defaultKillTargetWeeks,
                    lineupSlotID: slot.id
                )
                state.ledger.append(record)
                state.teams[teamIdx].nextLineupIndex = (idx + 1) % count
                return .success(record)
            }
            idx = (idx + 1) % count
        }
        return .success(nil)   // lineup has no regular slot to start on
    }

    /// Auto-starts every team that is NOT currently fighting a monster on the FIRST
    /// monster of the lineup (client: "when I set the lineup, every idle team should
    /// begin at the start of the lineup"). Idle teams are reset to the top of the lineup
    /// first; teams already mid-battle are left exactly where they are. No-op while a
    /// miniboss is active (all battles are paused) or when the lineup is empty. Battle
    /// setup — not undoable.
    @discardableResult
    public static func startIdleTeamsFromLineup(into state: inout AppState, at: Date) -> [MonsterRecord] {
        guard state.aliveMiniboss == nil, !state.lineup.isEmpty else { return [] }
        var spawned: [MonsterRecord] = []
        for team in state.teams where state.aliveRegularRecord(forTeam: team.id) == nil {
            if let idx = state.teams.firstIndex(where: { $0.id == team.id }) {
                state.teams[idx].nextLineupIndex = 0   // begin at the start of the lineup
            }
            if case .success(let record?) = spawnFromLineup(into: &state, teamID: team.id, at: at) {
                spawned.append(record)
            }
        }
        return spawned
    }

    // MARK: - Reset one student's practice (testing aid)

    /// Wipes a single student's logged practice — every combat-log entry they created —
    /// zeroing their daily average and their leaderboard contribution. The client asked
    /// for a per-student reset "mostly for testing purposes".
    ///
    /// Safety: any past ATTACK action that included this student is dropped from the undo
    /// history (so undo can never try to reverse an entry that no longer exists), but the
    /// dropped actions are NOT reversed — every monster stays exactly as defeated/alive as
    /// it was, every OTHER student's entries are untouched, and all frozen past boards
    /// (denormalized snapshots) are unaffected. Not itself undoable.
    public static func resetStudentPractice(into state: inout AppState, studentID: UUID) {
        let removedIDs = Set(state.combatLog.entries
            .filter { $0.studentID == studentID }
            .map { $0.id })
        guard !removedIDs.isEmpty else { return }
        state.combatLog.removeEntries(withIDs: removedIDs)
        // An attack action's entries all share one attacker, so this drops exactly the
        // actions this student authored, leaving every other action undoable.
        state.actions.removeAll { action in
            if case .attack(let a) = action {
                return a.entries.contains { $0.studentID == studentID }
            }
            return false
        }
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
        // MINIBOSS PAUSE GATE: while a miniboss is alive it is the only legal target.
        // This single check IS the pause — paused monsters cannot change because
        // nothing can touch them, so their state is preserved with no snapshotting.
        if let miniboss = state.aliveMiniboss, miniboss.id != targetRecordID {
            return .failure(.minibossActive)
        }

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

            // Carry the leftover onto the successor, or stop. Boundaries (client
            // default): overkill never crosses the miniboss boundary — no carry OUT
            // of a defeated miniboss and no carry INTO a triggered one; the leftover
            // is discarded. The remaining-HP > 0 check is a defensive guard against a
            // zero-HP successor (only possible with a pathological minimumMonsterHP
            // of 0) looping forever.
            guard pending > 0,
                  current.kind == .regular,
                  let successor = outcome.spawnedRecord,
                  successor.kind == .regular,
                  state.remainingHP(of: successor) > 0 else { break }
            current = successor
        }

        state.actions.append(.attack(AttackAction(entries: entries, defeats: defeats)))
        return .success(AttackResult(entries: entries, defeats: defeats))
    }

    // MARK: - Most-recent-entry policy (edit / delete)

    /// The most recent ATTACK action in scope — i.e. the only thing editable/deletable
    /// under the client's most-recent-only policy — or nil if the last action in scope
    /// is an admin action or nothing exists. Uses the SAME scope resolution as undo,
    /// so a UI affordance driven by this can never disagree with what edit/delete/undo
    /// will actually touch.
    public static func mostRecentAttack(in state: AppState, teamScope: UUID? = nil) -> AttackAction? {
        guard let i = lastActionIndex(forTeam: teamScope, state: state),
              case .attack(let a) = state.actions[i] else { return nil }
        return a
    }

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

        // Edit is undo + re-apply. If a miniboss is active, re-applying against a paused
        // regular monster would hit the pause gate AFTER the undo already ran — silently
        // turning "edit" into "delete". Refuse up front. Exception: editing the attack
        // that TRIGGERED the miniboss is legal, because its own undo removes the miniboss
        // (and the re-apply may then re-trigger it) — detect that via its defeats.
        if let miniboss = state.aliveMiniboss, original.monsterRecordID != miniboss.id {
            let thisAttackTriggeredIt = a.defeats.contains { $0.spawnedRecord?.id == miniboss.id }
            guard thisAttackTriggeredIt else { return .failure(.minibossActive) }
        }

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
        // Same pause gate as attack(): autokilling a paused regular monster would
        // spawn its successor mid-miniboss. Autokilling the miniboss itself is
        // allowed — that's how the teacher ends a miniboss early.
        if let miniboss = state.aliveMiniboss, miniboss.id != recordID {
            return .failure(.minibossActive)
        }
        let outcome = resolveDefeat(into: &state, defeatedRecordID: recordID,
                                    reason: .autokill, killingEntryID: nil, at: at)
        state.actions.append(.autokill(AutokillAction(outcome: outcome, at: at)))
        return .success(outcome)
    }

    // MARK: - Lineup management (teacher admin)

    /// Replaces the shared monster lineup (add/delete/reorder = whole-array replace).
    /// Explicitly allowed while a miniboss is active — the client uses the pause for
    /// inventory management and catching up lagging teams. Affects FUTURE spawns
    /// only; live and paused monsters are untouched. Undoable (global scope).
    @discardableResult
    public static func setLineup(into state: inout AppState,
                                 slots: [LineupSlot],
                                 at: Date) -> Result<Void, EngineError> {
        guard slots.allSatisfy({ slot in
            state.monsterCatalog.contains(where: { $0.id == slot.templateID })
        }) else { return .failure(.templateNotFound) }

        let previous = state.lineup
        state.lineup = slots
        state.actions.append(.setLineup(LineupChangeAction(previous: previous, new: slots, at: at)))
        return .success(())
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
        case .setLineup(let a):
            state.lineup = a.previous
        }

        state.actions.remove(at: i)
        return true
    }

    // MARK: - Shared internals

    /// How a team's next spawn resolves against the shared lineup.
    private enum SpawnResolution {
        /// Spawn a regular monster from this template (slot nil = legacy fallback).
        case regular(templateID: UUID, slotID: UUID?, pointerChange: TeamPointerChange?)
        /// The team's next unspent slot is a miniboss — trigger the global fight.
        case minibossTrigger(slot: LineupSlot)
        /// Nothing to spawn (no team, or a lineup with no usable slot).
        case none
    }

    /// Walks the lineup from the team's pointer: the first REGULAR slot is consumed
    /// (pointer advances past it); an UNSPENT miniboss slot triggers the global fight
    /// (pointer deliberately NOT advanced — the spent rule consumes the slot, which
    /// keeps the trigger trivially undoable); spent miniboss slots are skipped. An
    /// empty lineup falls back to the legacy cyclic-next-template rule so the app
    /// works before the teacher has configured a lineup.
    private static func resolveNextSpawn(forTeam teamID: UUID,
                                         fallbackTemplate: UUID,
                                         state: AppState) -> SpawnResolution {
        guard !state.lineup.isEmpty else {
            let template = nextRegularTemplate(after: fallbackTemplate, in: state) ?? fallbackTemplate
            return .regular(templateID: template, slotID: nil, pointerChange: nil)
        }
        guard let teamIdx = state.teams.firstIndex(where: { $0.id == teamID }) else { return .none }

        let count = state.lineup.count
        let rawPointer = state.teams[teamIdx].nextLineupIndex
        var idx = ((rawPointer % count) + count) % count   // safe modulo (edits shrink the lineup)

        for _ in 0..<count {
            let slot = state.lineup[idx]
            switch state.monsterCatalog.first(where: { $0.id == slot.templateID })?.kind {
            case .regular:
                let change = TeamPointerChange(teamID: teamID,
                                               fromIndex: rawPointer,
                                               toIndex: (idx + 1) % count)
                return .regular(templateID: slot.templateID, slotID: slot.id, pointerChange: change)
            case .miniboss where !state.isSpent(slot: slot):
                return .minibossTrigger(slot: slot)
            default:
                break   // spent miniboss, or a slot whose template left the catalog — skip
            }
            idx = (idx + 1) % count
        }
        return .none   // pathological: lineup holds only spent/orphaned slots
    }

    /// Mark a monster defeated, freeze its top-3 board, and spawn what follows:
    /// a regular defeat spawns the team's next lineup monster — or TRIGGERS the
    /// global miniboss if that's their next slot; a miniboss defeat spawns the
    /// triggering team's next regular monster (the "resume" — everyone else simply
    /// becomes attackable again). Used by both a final-blow kill and an autokill.
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

        var spawned: MonsterRecord? = nil
        var pointerChange: TeamPointerChange? = nil

        if let defeated = state.monsterRecord(defeatedRecordID),
           // Regular defeat → that team spawns next. Miniboss defeat → the TRIGGERING
           // team resumes (it is the only team left without an alive monster).
           let teamID = (defeated.kind == .regular ? defeated.teamID : defeated.triggeredByTeamID) {

            switch resolveNextSpawn(forTeam: teamID, fallbackTemplate: defeated.templateID, state: state) {
            case .regular(let templateID, let slotID, let change):
                let successor = MonsterRecord(
                    templateID: templateID,
                    kind: .regular,
                    teamID: teamID,
                    spawnedAt: at,
                    spawnSequence: state.nextSpawnSequence,
                    spawnedByEntryID: killingEntryID,
                    spawnAverages: teamSpawnAverages(teamID: teamID, state: state, at: at),
                    // Inherit a regular predecessor's kill target for battle
                    // continuity; after a miniboss, start from the default.
                    killTargetWeeks: defeated.kind == .regular ? defeated.killTargetWeeks
                                                               : state.settings.defaultKillTargetWeeks,
                    lineupSlotID: slotID
                )
                state.ledger.append(successor)
                spawned = successor
                if let change = change,
                   let teamIdx = state.teams.firstIndex(where: { $0.id == teamID }) {
                    state.teams[teamIdx].nextLineupIndex = change.toIndex
                    pointerChange = change
                }

            case .minibossTrigger(let slot):
                // Defensive: never two live minibosses (the pause gates make a second
                // trigger unreachable while one is alive).
                if state.aliveMiniboss == nil {
                    let miniboss = MonsterRecord(
                        templateID: slot.templateID,
                        kind: .miniboss,
                        teamID: nil,                                  // fought by everyone
                        spawnedAt: at,
                        spawnSequence: state.nextSpawnSequence,
                        spawnedByEntryID: killingEntryID,
                        spawnAverages: allStudentAverages(state: state, at: at), // frozen at trigger
                        killTargetWeeks: state.settings.minibossKillTargetWeeks,
                        lineupSlotID: slot.id,                        // marks the slot spent
                        triggeredByTeamID: teamID
                    )
                    state.ledger.append(miniboss)
                    spawned = miniboss
                }

            case .none:
                break
            }
        }

        return DefeatOutcome(defeatedRecordID: defeatedRecordID,
                             frozenFinalLeaderboard: frozen,
                             spawnedRecord: spawned,
                             teamPointerChange: pointerChange,
                             reason: reason)
    }

    /// Reverse a defeat: drop the spawned successor (entry-free by the time this runs,
    /// because undo removes the whole attack chain's entries first), restore the
    /// team's lineup pointer, and revive the defeated record. Removing a triggered
    /// miniboss automatically un-spends its slot and lifts the pause.
    private static func reverseDefeat(_ outcome: DefeatOutcome, _ state: inout AppState) {
        if let successor = outcome.spawnedRecord {
            removeRecordIfEmpty(successor.id, &state)
        }
        if let change = outcome.teamPointerChange,
           let teamIdx = state.teams.firstIndex(where: { $0.id == change.teamID }) {
            state.teams[teamIdx].nextLineupIndex = change.fromIndex
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

    /// Miniboss HP inputs: EVERY active student's daily average, regardless of team,
    /// frozen at trigger time.
    private static func allStudentAverages(state: AppState, at: Date) -> [StudentAverage] {
        let calendar = state.settings.resolvedCalendar
        return state.activeStudents
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
