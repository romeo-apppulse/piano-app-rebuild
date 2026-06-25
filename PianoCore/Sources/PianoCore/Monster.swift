//
//  Monster.swift — monster catalog templates, spawned instances (records), and
//  frozen leaderboard snapshots.
//
//  A MonsterTemplate is the reusable art/name in the deck. A MonsterRecord is one
//  *spawned instance* in a battle. "Current monster" == an alive record
//  (defeatedAt == nil). History lives on defeated records, frozen so the sliding
//  3-month averaging window can never retroactively change a past monster.
//

import Foundation

public enum MonsterKind: String, Codable, Hashable {
    case regular    // fought by one team
    case miniboss   // fought by all students
}

/// A reusable monster definition (the "deck"). Image bytes stay as files in the
/// app's Documents directory, referenced by name — optional so a missing image
/// can never crash via a force-unwrapped subscript (the old app's `[0]` bug).
public struct MonsterTemplate: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var imageFileName: String?
    public var artist: String?
    public var kind: MonsterKind

    public init(id: UUID = UUID(),
                name: String,
                imageFileName: String? = nil,
                artist: String? = nil,
                kind: MonsterKind) {
        self.id = id
        self.name = name
        self.imageFileName = imageFileName
        self.artist = artist
        self.kind = kind
    }
}

/// One contributor's daily-average, frozen at the instant a monster spawned.
/// Stored as an explicit array (not [UUID: Double]) so appState.json stays a
/// clean, readable object rather than a flat alternating key/value array.
public struct StudentAverage: Codable, Hashable {
    public let studentID: UUID
    public let average: Double

    public init(studentID: UUID, average: Double) {
        self.studentID = studentID
        self.average = average
    }
}

/// A frozen leaderboard row captured at a monster's defeat. The display name is
/// denormalized so the past-monster board survives a later rename or soft-delete.
public struct LeaderboardSnapshotRow: Identifiable, Codable, Hashable {
    public let id: UUID            // studentID
    public let displayName: String
    public let totalDamage: Int
    public let rank: Int           // dense, 1-based

    public init(id: UUID, displayName: String, totalDamage: Int, rank: Int) {
        self.id = id
        self.displayName = displayName
        self.totalDamage = totalDamage
        self.rank = rank
    }
}

/// A single spawned monster instance. The combat log segments by `id`.
public struct MonsterRecord: Identifiable, Codable, Hashable {
    public let id: UUID
    public let templateID: UUID
    public let kind: MonsterKind
    /// Regular → the team fighting it. Miniboss → nil (all students).
    public let teamID: UUID?
    public let spawnedAt: Date
    /// Monotonic spawn ordering; "previous monster" for a team = its last defeated
    /// record by greatest spawnSequence.
    public let spawnSequence: Int
    /// The killing entry that spawned this successor (undo back-pointer). nil for
    /// the first monster of a battle or a manually/teacher-spawned one.
    public let spawnedByEntryID: UUID?

    // --- IMMUTABLE HP inputs, frozen at spawn → window drift can't corrupt past HP ---
    public var spawnAverages: [StudentAverage]

    // --- MUTABLE HP inputs (HP recomputes live from these) ---
    public var killTargetWeeks: Int
    /// Teacher add/subtract HP (backdoor #1). Applied as an offset so it survives a
    /// kill-target recompute; never a combat-log/damage entry.
    public var backdoorHPDelta: Int

    /// Migration-only: pins this instance's HP to the value it had in the old app so
    /// the HP bar is continuous on day one. nil for natively spawned monsters.
    public var legacyFixedHP: Int?

    // --- Lifecycle ---
    public var defeatedAt: Date?
    public var defeatedByEntryID: UUID?
    public var finalLeaderboard: [LeaderboardSnapshotRow]?

    public var isAlive: Bool { defeatedAt == nil }

    public init(id: UUID = UUID(),
                templateID: UUID,
                kind: MonsterKind,
                teamID: UUID?,
                spawnedAt: Date,
                spawnSequence: Int,
                spawnedByEntryID: UUID? = nil,
                spawnAverages: [StudentAverage] = [],
                killTargetWeeks: Int,
                backdoorHPDelta: Int = 0,
                legacyFixedHP: Int? = nil,
                defeatedAt: Date? = nil,
                defeatedByEntryID: UUID? = nil,
                finalLeaderboard: [LeaderboardSnapshotRow]? = nil) {
        self.id = id
        self.templateID = templateID
        self.kind = kind
        self.teamID = teamID
        self.spawnedAt = spawnedAt
        self.spawnSequence = spawnSequence
        self.spawnedByEntryID = spawnedByEntryID
        self.spawnAverages = spawnAverages
        self.killTargetWeeks = killTargetWeeks
        self.backdoorHPDelta = backdoorHPDelta
        self.legacyFixedHP = legacyFixedHP
        self.defeatedAt = defeatedAt
        self.defeatedByEntryID = defeatedByEntryID
        self.finalLeaderboard = finalLeaderboard
    }
}
