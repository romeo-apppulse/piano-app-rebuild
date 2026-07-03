//
//  AppState.swift — the single serialized root, persisted as one atomic appState.json.
//
//  Authoritative state vs derived state (stated explicitly so "do not scatter state"
//  is honored intentionally):
//    AUTHORITATIVE (stored): roster, teams, catalog, ledger, combatLog, actions, settings.
//    DERIVED (never stored): every leaderboard, every daily average, every monster's
//      effective HP — all computed on demand from the above.
//
//  The ledger holds mutable per-monster facts that are genuinely NOT derivable from
//  the attack log (frozen spawn averages, kill target, backdoor delta, frozen final
//  boards). These are kept on the ledger by design, not scattered ad hoc.
//

import Foundation

public struct AppState: Codable, Equatable {
    public var schemaVersion: Int
    public var students: [Student]
    public var teams: [Team]
    public var monsterCatalog: [MonsterTemplate]
    /// The shared, ordered monster lineup (see Lineup.swift). Empty = legacy
    /// cyclic-next-template spawning.
    public var lineup: [LineupSlot]
    public var ledger: [MonsterRecord]
    public var combatLog: CombatLog
    public var actions: [GameAction]
    public var settings: GameSettings

    public static let currentSchemaVersion = 2

    public init(schemaVersion: Int = AppState.currentSchemaVersion,
                students: [Student] = [],
                teams: [Team] = [],
                monsterCatalog: [MonsterTemplate] = [],
                lineup: [LineupSlot] = [],
                ledger: [MonsterRecord] = [],
                combatLog: CombatLog = CombatLog(),
                actions: [GameAction] = [],
                settings: GameSettings = GameSettings()) {
        self.schemaVersion = schemaVersion
        self.students = students
        self.teams = teams
        self.monsterCatalog = monsterCatalog
        self.lineup = lineup
        self.ledger = ledger
        self.combatLog = combatLog
        self.actions = actions
        self.settings = settings
    }

    // MARK: - Lookups (read-only conveniences; nil-safe, no force-unwraps)

    public func student(_ id: UUID) -> Student? {
        students.first { $0.id == id }
    }

    /// Display name for a student id, with a safe fallback for orphaned references.
    public func displayName(_ id: UUID) -> String {
        student(id)?.name ?? "Unknown"
    }

    public var activeStudents: [Student] {
        students.filter { $0.isActive }
    }

    public func monsterRecord(_ id: UUID) -> MonsterRecord? {
        ledger.first { $0.id == id }
    }

    /// The alive regular monster a team is currently fighting, if any.
    public func aliveRegularRecord(forTeam teamID: UUID) -> MonsterRecord? {
        ledger.first { $0.teamID == teamID && $0.kind == .regular && $0.isAlive }
    }

    /// The alive miniboss, if a miniboss event is currently running.
    public var aliveMiniboss: MonsterRecord? {
        ledger.first { $0.kind == .miniboss && $0.isAlive }
    }

    /// A team's most recently defeated regular monster (its "previous monster").
    public func previousDefeatedRecord(forTeam teamID: UUID) -> MonsterRecord? {
        ledger.filter { $0.teamID == teamID && $0.kind == .regular && !$0.isAlive }
              .max(by: { $0.spawnSequence < $1.spawnSequence })
    }

    // MARK: - Derived game values (computed, never stored)

    /// Total damage logged against a monster instance.
    public func damageDealt(toMonster recordID: UUID) -> Int {
        combatLog.entries.reduce(0) { $0 + ($1.monsterRecordID == recordID ? $1.amount : 0) }
    }

    /// A monster's live effective HP (frozen averages × current kill target + delta, floored).
    public func effectiveHP(of record: MonsterRecord) -> Int {
        MonsterMath.effectiveHP(for: record, minimumHP: settings.minimumMonsterHP)
    }

    /// HP remaining before defeat (clamped at 0 — never negative).
    public func remainingHP(of record: MonsterRecord) -> Int {
        max(0, effectiveHP(of: record) - damageDealt(toMonster: record.id))
    }

    /// The next spawn-ordering number (monotonic across the whole ledger).
    public var nextSpawnSequence: Int {
        (ledger.map { $0.spawnSequence }.max() ?? -1) + 1
    }

    /// Whether a MINIBOSS lineup slot has been consumed: true if any monster instance
    /// was spawned from it (alive = fight in progress, defeated = already fought).
    /// Undo-safe by construction: undoing the trigger deletes the record, un-spending
    /// the slot. Meaningless for regular slots (every team consumes those
    /// independently) — only the miniboss spawn path consults it.
    public func isSpent(slot: LineupSlot) -> Bool {
        ledger.contains { $0.lineupSlotID == slot.id }
    }
}
