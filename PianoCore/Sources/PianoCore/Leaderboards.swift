//
//  Leaderboards.swift — the three DISTINCT leaderboards, all derived (never stored).
//
//    1. Current-monster — damage vs one alive monster instance; resets per monster
//       automatically because it is just a filter on that instance's id.
//    2. Past-monster    — the frozen top-3 snapshot of a team's previous monster.
//    3. All-time        — cumulative damage per student since added (incl. seeds).
//
//  RANKING RULE (client decision, from her own example): tied students share the
//  same placement, and the next distinct total gets the NEXT number — two students
//  tied at 439 are both 1st, the next student is 2nd (not 3rd). Applied identically
//  to all three boards. A stable name-then-id tiebreak keeps ordering deterministic.
//
//  NOTE: the client's verbal formula ("1 + number strictly ahead") would instead make
//  the next student 3rd; her worked example overrides it. If she ever wants the
//  1-1-3 style, change ONLY the rank increment in `ranked` (rank = position of the
//  first row with this total, i.e. count of strictly-better students + 1).
//

import Foundation

public struct LeaderboardRow: Identifiable, Codable, Hashable {
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

public enum Leaderboards {

    /// Shared-placement ranking over pre-summed totals (see the header rule): equal
    /// totals share a placement; the next distinct total gets the next number, no
    /// gaps (1-1-2). Ties ordered by name then id for stability.
    public static func ranked(_ totals: [(id: UUID, name: String, total: Int)]) -> [LeaderboardRow] {
        let sorted = totals.sorted { a, b in
            if a.total != b.total { return a.total > b.total }
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.id.uuidString < b.id.uuidString   // final stable tiebreak: fully deterministic order
        }
        var rows: [LeaderboardRow] = []
        var lastTotal: Int? = nil
        var rank = 0
        for t in sorted {
            if lastTotal != t.total {
                rank += 1
                lastTotal = t.total
            }
            rows.append(LeaderboardRow(id: t.id, displayName: t.name, totalDamage: t.total, rank: rank))
        }
        return rows
    }

    // MARK: - 1. Current-monster (resets per monster for free)

    /// Standings against a single alive monster instance. Includes only students who
    /// have hit it. Scoped purely by `monsterRecordID`, so a new monster starts empty.
    public static func currentMonster(recordID: UUID, state: AppState) -> [LeaderboardRow] {
        var totals: [UUID: Int] = [:]
        for entry in state.combatLog.entries where entry.monsterRecordID == recordID {
            totals[entry.studentID, default: 0] += entry.amount
        }
        return ranked(totals.map { (id: $0.key, name: state.displayName($0.key), total: $0.value) })
    }

    /// Convenience: the current-monster board for the regular monster a team is fighting.
    public static func currentMonster(forTeam teamID: UUID, state: AppState) -> [LeaderboardRow] {
        guard let record = state.aliveRegularRecord(forTeam: teamID) else { return [] }
        return currentMonster(recordID: record.id, state: state)
    }

    // MARK: - 2. Past-monster (frozen snapshot, one back)

    /// The frozen top-3 of a team's previous (most-recently-defeated) regular monster.
    public static func pastMonster(forTeam teamID: UUID, state: AppState) -> [LeaderboardSnapshotRow] {
        state.previousDefeatedRecord(forTeam: teamID)?.finalLeaderboard ?? []
    }

    /// The frozen top-3 of the most recently defeated MINIBOSS — its own dedicated
    /// slot (client decision), distinct from the per-team past-monster boards.
    public static func pastMiniboss(state: AppState) -> [LeaderboardSnapshotRow] {
        state.ledger.filter { $0.kind == .miniboss && !$0.isAlive }
            .max(by: { $0.spawnSequence < $1.spawnSequence })?
            .finalLeaderboard ?? []
    }

    // MARK: - 3. All-time (cumulative since added)

    /// Cumulative total damage per student across ALL entries (including `.migration`
    /// seeds). Every active student appears, even with 0 damage. Top 5 distinction is
    /// a view concern; this returns full dense ranks so the view can include ties at
    /// the cutoff rather than truncating arbitrarily.
    public static func allTime(state: AppState) -> [LeaderboardRow] {
        // Single, explicit membership rule: the board shows ACTIVE students only.
        // Soft-deleted students keep their history (totals return if reactivated) but
        // are hidden from the displayed board — consistent with Student.isActive.
        // (Flagged for the client: confirm a removed student should drop off all-time
        // rather than remain as a hall-of-fame.)
        let activeIDs = Set(state.activeStudents.map { $0.id })
        var totals: [UUID: Int] = [:]
        for student in state.activeStudents { totals[student.id] = 0 } // newcomers listed at 0
        for entry in state.combatLog.entries where activeIDs.contains(entry.studentID) {
            totals[entry.studentID, default: 0] += entry.amount
        }
        return ranked(totals.map { (id: $0.key, name: state.displayName($0.key), total: $0.value) })
    }
}
