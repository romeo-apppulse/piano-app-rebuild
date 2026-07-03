//
//  Migration.swift — one-time, pure mapping of legacy data into the new AppState.
//
//  Principles (client-confirmed):
//    • Reuse existing UUIDs where the legacy data has them (teams, students); mint
//      where it doesn't (monsters had no ids — identity was the name).
//    • Join by exact name string — the only joins that exist. A collision or a miss
//      is FLAGGED in the report and left unlinked; never silently attached to a
//      placeholder (the old app's resurrection bug).
//    • The in-flight monster per battle becomes one alive MonsterRecord pinned to its
//      legacy HP (legacyFixedHP) so the HP bar is continuous on day one.
//    • Seeding is OPTIONAL (settings.seedLeaderboardsFromLegacyScore): one labeled
//      `.migration` entry per student carrying their current score — feeds the
//      leaderboards, EXCLUDED from daily averages. Off = boards start blank.
//    • No dated history exists to migrate; real averages accrue from live use.
//
//  This function is PURE (no filesystem). The caller (first-launch flow) is
//  responsible for the idempotence guard: migrate only when no appState.json exists,
//  and never delete the legacy files (they are the rollback).
//

import Foundation

public struct MigrationReport: Equatable {
    /// Human-readable flags the teacher should review (collisions, orphans, drift).
    public var warnings: [String] = []
    /// Non-actionable notes about what happened (counts, seeding mode).
    public var notes: [String] = []

    public init() {}
}

public enum Migration {

    public static func migrate(_ legacy: LegacyData,
                               at now: Date,
                               settings: GameSettings = GameSettings()) -> (state: AppState, report: MigrationReport) {
        var report = MigrationReport()

        // --- Teams: reuse ids, name-keyed join map. Duplicate names are ambiguous —
        // remove them from the join map entirely so nothing silently mislinks.
        var teams: [Team] = []
        var teamIDsByName: [String: UUID] = [:]
        var duplicateTeamNames: Set<String> = []
        for legacyTeam in legacy.teams {
            let team = Team(id: legacyTeam.id ?? UUID(), name: legacyTeam.name)
            teams.append(team)
            if teamIDsByName[legacyTeam.name] != nil {
                duplicateTeamNames.insert(legacyTeam.name)
            } else {
                teamIDsByName[legacyTeam.name] = team.id
            }
        }
        for name in duplicateTeamNames {
            teamIDsByName.removeValue(forKey: name)
            report.warnings.append("Duplicate team name '\(name)': students and battles referencing it were left unlinked — resolve by hand.")
        }

        // --- Monster catalog: mint ids (legacy monsters had none).
        var catalog: [MonsterTemplate] = []
        var templateIDsByName: [String: UUID] = [:]
        var duplicateMonsterNames: Set<String> = []
        for legacyMonster in legacy.monsters {
            let template = MonsterTemplate(name: legacyMonster.name,
                                           imageFileName: legacyMonster.img,
                                           artist: legacyMonster.artist,
                                           kind: .regular)
            catalog.append(template)
            if templateIDsByName[legacyMonster.name] != nil {
                duplicateMonsterNames.insert(legacyMonster.name)
            } else {
                templateIDsByName[legacyMonster.name] = template.id
            }
        }
        for name in duplicateMonsterNames {
            templateIDsByName.removeValue(forKey: name)
            report.warnings.append("Duplicate monster name '\(name)': battles referencing it were left unlinked — resolve by hand.")
        }
        if let legacyMiniboss = legacy.miniboss {
            catalog.append(MonsterTemplate(name: legacyMiniboss.name,
                                           imageFileName: legacyMiniboss.img,
                                           kind: .miniboss))
            report.notes.append("Imported miniboss '\(legacyMiniboss.name)'. (The old app kept only the last-saved miniboss.)")
        }

        // --- Students: reuse ids, resolve team by name, all-time anchored at migration.
        var students: [Student] = []
        for legacyStudent in legacy.students {
            let teamID = teamIDsByName[legacyStudent.teamName]
            if teamID == nil && !legacyStudent.teamName.isEmpty {
                report.warnings.append("Student '\(legacyStudent.name)': team '\(legacyStudent.teamName)' not found or ambiguous — left unassigned.")
            }
            students.append(Student(id: legacyStudent.id ?? UUID(),
                                    name: legacyStudent.name,
                                    teamID: teamID,
                                    createdAt: now,
                                    isActive: true))
        }

        // --- In-flight battles: one ALIVE record per battle, HP pinned to the legacy
        // value. Unresolvable names are flagged and skipped — never placeholdered.
        var ledger: [MonsterRecord] = []
        var aliveRecordIDByTeamID: [UUID: UUID] = [:]
        var legacyDmgByTeamID: [UUID: Int] = [:]
        var spawnSequence = 0
        for legacyBattle in legacy.battles {
            guard let templateID = templateIDsByName[legacyBattle.monsterName] else {
                report.warnings.append("Battle for team '\(legacyBattle.teamName)': monster '\(legacyBattle.monsterName)' not found or ambiguous — battle not imported.")
                continue
            }
            guard let teamID = teamIDsByName[legacyBattle.teamName] else {
                report.warnings.append("Battle vs '\(legacyBattle.monsterName)': team '\(legacyBattle.teamName)' not found or ambiguous — battle not imported.")
                continue
            }
            guard aliveRecordIDByTeamID[teamID] == nil else {
                report.warnings.append("Team '\(legacyBattle.teamName)' has more than one battle — only the first was imported.")
                continue
            }
            let record = MonsterRecord(templateID: templateID,
                                       kind: .regular,
                                       teamID: teamID,
                                       spawnedAt: now,
                                       spawnSequence: spawnSequence,
                                       spawnAverages: [],   // no history exists to freeze
                                       killTargetWeeks: settings.defaultKillTargetWeeks,
                                       legacyFixedHP: legacyBattle.hp)
            ledger.append(record)
            aliveRecordIDByTeamID[teamID] = record.id
            legacyDmgByTeamID[teamID] = legacyBattle.dmg
            spawnSequence += 1
        }

        // --- Optional day-one seeding: one .migration entry per scored student,
        // attached to their team's imported battle. Feeds leaderboards (all-time +
        // current), EXCLUDED from daily averages by origin.
        var combatLog = CombatLog()
        if settings.seedLeaderboardsFromLegacyScore {
            var seededDmgByTeamID: [UUID: Int] = [:]
            for (student, legacyStudent) in zip(students, legacy.students) where legacyStudent.score > 0 {
                guard let teamID = student.teamID, let recordID = aliveRecordIDByTeamID[teamID] else {
                    report.warnings.append("Student '\(student.name)': score \(legacyStudent.score) could not be seeded (no linked team battle) — their boards start at 0.")
                    continue
                }
                combatLog.appendEntry(studentID: student.id, monsterRecordID: recordID,
                                      amount: legacyStudent.score, timestamp: now, origin: .migration)
                seededDmgByTeamID[teamID, default: 0] += legacyStudent.score
            }
            // Drift check: student scores are authoritative; note any mismatch vs the
            // legacy battle aggregate so the teacher can sanity-check the HP bars.
            for (teamID, legacyDmg) in legacyDmgByTeamID {
                let seeded = seededDmgByTeamID[teamID] ?? 0
                if seeded != legacyDmg,
                   let teamName = teams.first(where: { $0.id == teamID })?.name {
                    report.warnings.append("Team '\(teamName)': seeded damage \(seeded) differs from the old battle total \(legacyDmg) (old HP-bar edits or resets) — student scores were trusted.")
                }
            }
            report.notes.append("Seeded starting scores for \(combatLog.entries.count) student(s); history begins at the rebuild.")
        } else {
            report.notes.append("Seeding disabled: leaderboards start blank; monsters start at full HP.")
        }

        report.notes.append("Imported \(teams.count) team(s), \(students.count) student(s), \(catalog.count) monster template(s), \(ledger.count) battle(s).")

        let state = AppState(students: students,
                             teams: teams,
                             monsterCatalog: catalog,
                             ledger: ledger,
                             combatLog: combatLog,
                             settings: settings)
        return (state, report)
    }
}
