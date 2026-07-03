//
//  GameAction.swift — the unified, ordered action history that powers undo.
//
//  Every state-mutating operation is recorded as one GameAction. "Undo" pops the
//  most recent action (scoped to a team in the UI) and reverses it. Crucially this
//  is ONE stack: attacks, teacher HP adjustments, kill-target changes, autokill, and
//  miniboss spawns all live here, so there is a single, consistent Undo — not two
//  parallel mechanisms. It also implements the client's entry policy: deletion is
//  top-down only (newest backward), which is exactly LIFO undo.
//
//  Each action carries enough information to reverse itself (prior values / the full
//  spawned successors) so undo never has to recompute or replay the whole history.
//

import Foundation

/// A team's lineup-pointer move caused by consuming a slot, stored so undo can put
/// the pointer back exactly.
public struct TeamPointerChange: Codable, Equatable {
    public let teamID: UUID
    public let fromIndex: Int
    public let toIndex: Int

    public init(teamID: UUID, fromIndex: Int, toIndex: Int) {
        self.teamID = teamID
        self.fromIndex = fromIndex
        self.toIndex = toIndex
    }
}

/// Captured when a monster dies (final blow OR autokill). Holds everything needed to
/// reverse the defeat: the frozen final board, the successor that was spawned (which
/// may be a triggered miniboss), and any lineup-pointer move.
public struct DefeatOutcome: Codable, Equatable {
    public enum Reason: String, Codable { case finalBlow, autokill }

    public let defeatedRecordID: UUID
    public let frozenFinalLeaderboard: [LeaderboardSnapshotRow]
    /// The successor spawned in the defeated monster's place — a regular monster, or
    /// the GLOBAL miniboss if this kill triggered one. nil when nothing respawns.
    public let spawnedRecord: MonsterRecord?
    /// The team lineup-pointer move this defeat caused (nil for a miniboss trigger,
    /// which deliberately does not advance the pointer — the slot is consumed by the
    /// spent rule instead, so undoing the trigger needs no pointer surgery).
    public let teamPointerChange: TeamPointerChange?
    public let reason: Reason

    public init(defeatedRecordID: UUID,
                frozenFinalLeaderboard: [LeaderboardSnapshotRow],
                spawnedRecord: MonsterRecord?,
                teamPointerChange: TeamPointerChange? = nil,
                reason: Reason) {
        self.defeatedRecordID = defeatedRecordID
        self.frozenFinalLeaderboard = frozenFinalLeaderboard
        self.spawnedRecord = spawnedRecord
        self.teamPointerChange = teamPointerChange
        self.reason = reason
    }
}

/// One logged attack, including everything it caused. With overkill CARRYOVER
/// (client decision), a single attack can produce a chain: a capped killing entry on
/// the dying monster, a kill+spawn, a carryover entry on the successor — possibly
/// repeating if the leftover kills the successor too. All entries and defeats of the
/// chain live on this one action, so a single undo reverses the entire chain
/// atomically (entries removed, spawns removed, defeats reverted, lock-ins cleared).
public struct AttackAction: Codable, Equatable {
    /// Every log entry this attack created, in creation order. The first entry is on
    /// the originally targeted monster; later entries are carryover on successors.
    public let entries: [CombatLogEntry]
    /// Every defeat this attack caused, in order (empty for a plain hit).
    public let defeats: [DefeatOutcome]

    public init(entries: [CombatLogEntry], defeats: [DefeatOutcome]) {
        self.entries = entries
        self.defeats = defeats
    }
}

/// Teacher add/subtract HP (backdoor #1). Stored as a signed delta; inverse is -delta.
public struct HPAdjustAction: Codable, Equatable {
    public let monsterRecordID: UUID
    public let delta: Int
    public let at: Date

    public init(monsterRecordID: UUID, delta: Int, at: Date) {
        self.monsterRecordID = monsterRecordID
        self.delta = delta
        self.at = at
    }
}

/// Change the kill-target weeks mid-battle (backdoor #2). Stores the previous value
/// for the inverse; HP recomputes automatically from the frozen spawn averages.
public struct KillTargetAction: Codable, Equatable {
    public let monsterRecordID: UUID
    public let previousWeeks: Int
    public let newWeeks: Int
    public let at: Date

    public init(monsterRecordID: UUID, previousWeeks: Int, newWeeks: Int, at: Date) {
        self.monsterRecordID = monsterRecordID
        self.previousWeeks = previousWeeks
        self.newWeeks = newWeeks
        self.at = at
    }
}

/// Teacher ends the current monster without a final blow (backdoor #3). Carries the
/// same DefeatOutcome as a normal kill, so undo reverses it identically.
public struct AutokillAction: Codable, Equatable {
    public let outcome: DefeatOutcome
    public let at: Date

    public init(outcome: DefeatOutcome, at: Date) {
        self.outcome = outcome
        self.at = at
    }
}

/// Teacher replaces the shared monster lineup (add/delete/reorder are all expressed
/// as a whole-array replacement). Allowed at any time — INCLUDING while a miniboss is
/// active, which is the client's intended catch-up/inventory window. Only affects
/// future spawns; undo restores the previous lineup.
public struct LineupChangeAction: Codable, Equatable {
    public let previous: [LineupSlot]
    public let new: [LineupSlot]
    public let at: Date

    public init(previous: [LineupSlot], new: [LineupSlot], at: Date) {
        self.previous = previous
        self.new = new
        self.at = at
    }
}

public enum GameAction: Codable, Equatable {
    case attack(AttackAction)
    case adjustHP(HPAdjustAction)
    case setKillTarget(KillTargetAction)
    case autokill(AutokillAction)
    case setLineup(LineupChangeAction)

    /// The monster instance this action concerns (used to resolve which team's
    /// timeline it belongs to for team-scoped undo). For an attack chain this is the
    /// ORIGINALLY targeted monster; carryover successors share its team. Lineup edits
    /// are global (nil) — reachable only by global (unscoped) undo, like miniboss
    /// attacks (a miniboss has no team).
    public var monsterRecordID: UUID? {
        switch self {
        case .attack(let a):        return a.entries.first?.monsterRecordID
        case .adjustHP(let a):      return a.monsterRecordID
        case .setKillTarget(let a): return a.monsterRecordID
        case .autokill(let a):      return a.outcome.defeatedRecordID
        case .setLineup:            return nil
        }
    }
}
