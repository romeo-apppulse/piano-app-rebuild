//
//  GameAction.swift — the unified, ordered action history that powers undo.
//
//  Every state-mutating operation is recorded as one GameAction. "Undo" pops the
//  most recent action (scoped to a team in the UI) and reverses it. Crucially this
//  is ONE stack: attacks, teacher HP adjustments, kill-target changes, autokill, and
//  miniboss spawns all live here, so there is a single, consistent Undo — not two
//  parallel mechanisms.
//
//  Each action carries enough information to reverse itself (prior values / the full
//  spawned successor) so undo never has to recompute or replay the whole history.
//

import Foundation

/// Captured when a monster dies (final blow OR autokill). Holds everything needed to
/// reverse the defeat: the frozen final board and the successor that was spawned.
public struct DefeatOutcome: Codable, Equatable {
    public enum Reason: String, Codable { case finalBlow, autokill }

    public let defeatedRecordID: UUID
    public let frozenFinalLeaderboard: [LeaderboardSnapshotRow]
    /// The successor spawned in the defeated monster's place. nil when nothing
    /// respawns (e.g. a miniboss event simply ending).
    public let spawnedRecord: MonsterRecord?
    public let reason: Reason

    public init(defeatedRecordID: UUID,
                frozenFinalLeaderboard: [LeaderboardSnapshotRow],
                spawnedRecord: MonsterRecord?,
                reason: Reason) {
        self.defeatedRecordID = defeatedRecordID
        self.frozenFinalLeaderboard = frozenFinalLeaderboard
        self.spawnedRecord = spawnedRecord
        self.reason = reason
    }
}

/// A logged attack. If it killed the monster, `causedDefeat` carries the kill+spawn
/// so a single undo of this action reverses the hit, the kill, the spawn, and the
/// leaderboard lock-in atomically.
public struct AttackAction: Codable, Equatable {
    public let entry: CombatLogEntry
    public let causedDefeat: DefeatOutcome?

    public init(entry: CombatLogEntry, causedDefeat: DefeatOutcome? = nil) {
        self.entry = entry
        self.causedDefeat = causedDefeat
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

/// Teacher spawns a miniboss event. The full record is stored so undo can remove it.
public struct MinibossSpawnAction: Codable, Equatable {
    public let spawnedRecord: MonsterRecord
    public let at: Date

    public init(spawnedRecord: MonsterRecord, at: Date) {
        self.spawnedRecord = spawnedRecord
        self.at = at
    }
}

public enum GameAction: Codable, Equatable {
    case attack(AttackAction)
    case adjustHP(HPAdjustAction)
    case setKillTarget(KillTargetAction)
    case autokill(AutokillAction)
    case spawnMiniboss(MinibossSpawnAction)

    /// The monster instance this action concerns (used to resolve which team's
    /// timeline it belongs to for team-scoped undo). nil only if not applicable.
    public var monsterRecordID: UUID? {
        switch self {
        case .attack(let a):        return a.entry.monsterRecordID
        case .adjustHP(let a):      return a.monsterRecordID
        case .setKillTarget(let a): return a.monsterRecordID
        case .autokill(let a):      return a.outcome.defeatedRecordID
        case .spawnMiniboss(let a): return a.spawnedRecord.id
        }
    }
}
