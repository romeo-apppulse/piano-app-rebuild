//
//  RealDataRehearsalTests.swift — Phase 2 of docs/MIGRATION-REHEARSAL.md.
//
//  Runs the REAL first-launch migration path against a captured COPY of the legacy
//  app's Documents folder and prints the full MigrationReport + a human-readable
//  summary for the client review. Strictly read-only on the capture; the only write
//  is a persistence round-trip into a fresh temp directory.
//
//  Skipped unless PIANO_REHEARSAL_DIR is set:
//
//      PIANO_REHEARSAL_DIR="$HOME/piano-rehearsal/capture-2026-07-04" \
//        swift test --filter RealDataRehearsalTests
//

import XCTest
@testable import PianoCore

final class RealDataRehearsalTests: XCTestCase {

    func testMigrateCapturedLegacyData() throws {
        guard let path = ProcessInfo.processInfo.environment["PIANO_REHEARSAL_DIR"],
              !path.isEmpty else {
            throw XCTSkip("Rehearsal only: set PIANO_REHEARSAL_DIR to a COPY of the legacy Documents capture.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)

        // 1. Load exactly as first launch will.
        guard let legacy = LegacyLoader.load(fromDirectory: directory) else {
            XCTFail("No legacy files found at \(path) — is this the right capture folder?")
            return
        }

        // 2. Migrate (pure; the capture is never written to).
        let (state, report) = Migration.migrate(legacy.data, at: Date())

        // 3. Structural invariants that must hold for ANY real data:
        //    nothing silently dropped — teams/students import 1:1, and every battle is
        //    either imported or explained by a warning.
        XCTAssertEqual(state.teams.count, legacy.data.teams.count, "team count changed in migration")
        XCTAssertEqual(state.students.count, legacy.data.students.count, "student count changed in migration")
        let skippedBattles = legacy.data.battles.count - state.ledger.count
        XCTAssertGreaterThanOrEqual(skippedBattles, 0)
        if skippedBattles > 0 {
            XCTAssertGreaterThanOrEqual(report.warnings.count, skippedBattles,
                                        "battles were dropped without a warning explaining why")
        }
        // Migrated monsters must carry their legacy HP pin.
        for record in state.ledger {
            XCTAssertNotNil(record.legacyFixedHP, "migrated monster missing its legacy HP pin")
            XCTAssertTrue(record.isAlive)
        }
        // Seeds (if any) must never leak into daily averages.
        for student in state.students {
            XCTAssertEqual(PracticeMath.dailyAverage(forStudent: student.id,
                                                     entries: state.combatLog.entries,
                                                     now: Date(),
                                                     calendar: state.settings.resolvedCalendar),
                           0, "daily average must start at 0 — a seed leaked into the average")
        }

        // 4. Persistence round-trip into a fresh temp dir (what first launch writes).
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rehearsal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let persistence = JSONFilePersistence(directory: temp)
        try persistence.save(state)
        XCTAssertEqual(try persistence.load(), state, "appState.json did not round-trip")

        // 5. The report for the client review (Phase 3).
        printSummary(legacy: legacy.data, loaderWarnings: legacy.warnings, state: state, report: report)
    }

    // MARK: - Human-readable summary

    private func printSummary(legacy: LegacyData, loaderWarnings: [String],
                              state: AppState, report: MigrationReport) {
        var lines: [String] = []
        lines.append("================ MIGRATION REHEARSAL REPORT ================")
        lines.append("Legacy input : \(legacy.teams.count) team(s), \(legacy.students.count) student(s), \(legacy.monsters.count) monster(s), \(legacy.battles.count) battle(s), miniboss: \(legacy.miniboss?.name ?? "none")")
        lines.append("Migrated     : \(state.teams.count) team(s), \(state.students.count) student(s), \(state.monsterCatalog.count) template(s), \(state.ledger.count) battle(s), \(state.combatLog.entries.count) seed entrie(s)")
        lines.append("")

        lines.append("-- Teams & battles --")
        for team in state.teams {
            let members = state.students.filter { $0.teamID == team.id }.map { $0.name }
            if let record = state.aliveRegularRecord(forTeam: team.id) {
                let hp = state.effectiveHP(of: record)
                let dealt = state.damageDealt(toMonster: record.id)
                let monster = state.monsterCatalog.first { $0.id == record.templateID }?.name ?? "?"
                lines.append("  \(team.name): [\(members.joined(separator: ", "))] vs \(monster) — \(hp - dealt)/\(hp) HP (\(dealt) dealt)")
            } else {
                lines.append("  \(team.name): [\(members.joined(separator: ", "))] — NO battle imported")
            }
        }
        let unassigned = state.students.filter { $0.teamID == nil }.map { $0.name }
        if !unassigned.isEmpty {
            lines.append("  UNASSIGNED students: \(unassigned.joined(separator: ", "))")
        }
        lines.append("")

        lines.append("-- Seeded starting scores (leaderboards only, NOT averages) --")
        let seedRows = state.combatLog.entries.map { "  \(state.displayName($0.studentID)): \($0.amount)" }
        lines.append(contentsOf: seedRows.isEmpty ? ["  (none)"] : seedRows)
        lines.append("")

        lines.append("-- Warnings (\(report.warnings.count + loaderWarnings.count)) — review each with the client --")
        lines.append(contentsOf: (loaderWarnings + report.warnings).map { "  ⚠️ \($0)" })
        if report.warnings.isEmpty && loaderWarnings.isEmpty { lines.append("  (none)") }
        lines.append("")
        lines.append("-- Notes --")
        lines.append(contentsOf: report.notes.map { "  • \($0)" })
        lines.append("=============================================================")
        print(lines.joined(separator: "\n"))
    }
}
