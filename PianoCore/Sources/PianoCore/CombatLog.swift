//
//  CombatLog.swift — the append-only record of attacks (the source of truth for
//  live damage, leaderboards, and daily averages).
//
//  Two orderings are deliberately separated:
//    • `timestamp` — calendar time, drives day-bucketing and the 90-day window.
//    • `sequence`  — monotonic insertion order, drives "most recent first" + undo.
//  Storing only a date would make same-day undo order ambiguous; storing only an
//  instant would make day-bucketing depend on a timezone. We keep both.
//
//  IMMUTABILITY POLICY (client decision): only the most recent entry is editable or
//  deletable; older entries are locked. This type enforces the "no mutation" half
//  structurally: every CombatLogEntry field is `let`, `entries` is private(set), and
//  the only mutators are append + remove-by-id (used exclusively by the engine's
//  LIFO undo). "Edit most recent" is implemented in the engine as undo + re-apply,
//  so there is no code path that alters an existing entry in place.
//

import Foundation

public enum EntryOrigin: String, Codable, Hashable {
    case live        // a real logged attack — counts everywhere
    case migration   // day-one seed — counts for leaderboards, EXCLUDED from averages
    case extraPoints // bonus "Extra Points" damage — real damage to the monster and it
                     // counts on the damage leaderboards, but is EXCLUDED from practice
                     // averages (client: extra points are a reward, not practice time).
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
public struct CombatLog: Codable, Hashable {
    public private(set) var entries: [CombatLogEntry]
    public private(set) var nextSequence: Int

    public init(entries: [CombatLogEntry] = [], nextSequence: Int = 0) {
        self.entries = entries
        self.nextSequence = nextSequence
    }

    /// Appends a new entry stamped with the next sequence number and returns it.
    @discardableResult
    public mutating func appendEntry(studentID: UUID,
                                     monsterRecordID: UUID,
                                     amount: Int,
                                     timestamp: Date,
                                     origin: EntryOrigin = .live) -> CombatLogEntry {
        let entry = CombatLogEntry(sequence: nextSequence,
                                   studentID: studentID,
                                   monsterRecordID: monsterRecordID,
                                   amount: amount,
                                   timestamp: timestamp,
                                   origin: origin)
        entries.append(entry)
        nextSequence += 1
        return entry
    }

    /// Removes entries by id — the undo path. `nextSequence` is intentionally NOT
    /// decremented: sequence numbers are never reused, so ordering stays unambiguous
    /// even across undo + re-log.
    public mutating func removeEntries(withIDs ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
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
