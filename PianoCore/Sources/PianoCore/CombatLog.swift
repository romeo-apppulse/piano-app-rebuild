//
//  CombatLog.swift — the append-only record of attacks (the source of truth for
//  live damage, leaderboards, and daily averages).
//
//  Two orderings are deliberately separated:
//    • `timestamp` — calendar time, drives day-bucketing and the 3-month window.
//    • `sequence`  — monotonic insertion order, drives "most recent first" + undo.
//  Storing only a date would make same-day undo order ambiguous; storing only an
//  instant would make day-bucketing depend on a timezone. We keep both.
//

import Foundation

public enum EntryOrigin: String, Codable, Hashable {
    case live        // a real logged attack — counts everywhere
    case migration   // day-one seed — counts for leaderboards, EXCLUDED from averages
}

public struct CombatLogEntry: Identifiable, Codable, Hashable {
    public let id: UUID
    public let sequence: Int
    public let studentID: UUID
    /// Which spawned instance was hit — segments the log per monster.
    public let monsterRecordID: UUID
    public let amount: Int          // non-negative integer damage
    public let timestamp: Date
    public let origin: EntryOrigin

    public init(id: UUID = UUID(),
                sequence: Int,
                studentID: UUID,
                monsterRecordID: UUID,
                amount: Int,
                timestamp: Date,
                origin: EntryOrigin = .live) {
        self.id = id
        self.sequence = sequence
        self.studentID = studentID
        self.monsterRecordID = monsterRecordID
        self.amount = amount
        self.timestamp = timestamp
        self.origin = origin
    }
}

/// Append-only store of entries plus the next sequence number to hand out.
/// Mutation flows through the (later) command/store layer; `nextSequence` only
/// ever increases so undo can rely on `sequence` as a strict total order.
public struct CombatLog: Codable, Hashable {
    public var entries: [CombatLogEntry]
    public var nextSequence: Int

    public init(entries: [CombatLogEntry] = [], nextSequence: Int = 0) {
        self.entries = entries
        self.nextSequence = nextSequence
    }

    /// The globally most-recent entry by sequence (nil if the log is empty).
    public var mostRecent: CombatLogEntry? {
        entries.max(by: { $0.sequence < $1.sequence })
    }

    /// The most-recent entry hitting a given monster instance.
    public func mostRecent(forMonster recordID: UUID) -> CombatLogEntry? {
        entries.filter { $0.monsterRecordID == recordID }
               .max(by: { $0.sequence < $1.sequence })
    }
}
