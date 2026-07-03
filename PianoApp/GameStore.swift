//
//  GameStore.swift
//  PianoApp
//
//  The one @MainActor bridge between PianoCore's pure engine and SwiftUI.
//
//  Invariants:
//    • `state` is the single source of truth; it is private(set) so views can only
//      change it by calling a method here, and every method funnels the mutation
//      through GameEngine (gameplay) or a scoped `apply` (roster/catalog CRUD).
//    • Every mutation is followed by an atomic save via JSONFilePersistence.
//    • A failed save never crashes; it surfaces on `saveError` for the UI to show.
//

import Foundation
import PianoCore

@MainActor
final class GameStore: ObservableObject {
    @Published private(set) var state: AppState
    @Published var saveError: String?
    /// Set once on first launch if legacy data was migrated; drives a one-time report.
    @Published private(set) var migrationReport: MigrationReport?

    private let persistence: JSONFilePersistence

    /// First-launch flow (the caller passes the app's Documents dir in production):
    ///   1. If `appState.json` exists → load it.
    ///   2. Else if the old app's legacy files are present → migrate + save + report.
    ///   3. Else → a fresh empty state.
    init(directory: URL = GameStore.documentsDirectory) {
        let persistence = JSONFilePersistence(directory: directory)
        self.persistence = persistence

        if persistence.exists() {
            do {
                state = try persistence.load()
            } catch {
                // Corrupt/undecodable file: start clean rather than crash, but tell the
                // teacher — the rolling .bak files remain on disk for manual recovery.
                state = AppState()
                saveError = "Could not load saved data (\(error)). Started with an empty board; a backup may exist."
            }
        } else if let legacy = LegacyLoader.load(fromDirectory: directory) {
            let (migrated, report) = Migration.migrate(legacy.data, at: Date())
            state = migrated
            var report2 = report
            report2.notes.append(contentsOf: legacy.warnings)
            migrationReport = report2
            // Persist immediately so migration is one-time (idempotence guard = file exists).
            do { try persistence.save(migrated) }
            catch { saveError = "Migration succeeded but the first save failed: \(error)" }
        } else {
            state = AppState()
        }
    }

    nonisolated static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Gameplay mutations (every change goes through GameEngine)

    func spawnInitialMonster(teamID: UUID, templateID: UUID, at date: Date = Date()) {
        commit { _ = GameEngine.spawnInitialMonster(into: &$0, teamID: teamID, templateID: templateID, at: date) }
    }

    func attack(targetRecordID: UUID, studentID: UUID, amount: Int, at date: Date = Date()) {
        commit { _ = GameEngine.attack(into: &$0, targetRecordID: targetRecordID, studentID: studentID, amount: amount, at: date) }
    }

    func editMostRecentAttack(teamScope: UUID? = nil, newAmount: Int) {
        commit { _ = GameEngine.editMostRecentAttack(into: &$0, teamScope: teamScope, newAmount: newAmount) }
    }

    func deleteMostRecentEntry(teamScope: UUID? = nil) {
        commit { _ = GameEngine.deleteMostRecentEntry(into: &$0, teamScope: teamScope) }
    }

    func adjustHP(recordID: UUID, delta: Int, at date: Date = Date()) {
        commit { _ = GameEngine.adjustHP(into: &$0, recordID: recordID, delta: delta, at: date) }
    }

    func setKillTarget(recordID: UUID, weeks: Int, at date: Date = Date()) {
        commit { _ = GameEngine.setKillTarget(into: &$0, recordID: recordID, weeks: weeks, at: date) }
    }

    func autokill(recordID: UUID, at date: Date = Date()) {
        commit { _ = GameEngine.autokill(into: &$0, recordID: recordID, at: date) }
    }

    func setLineup(_ slots: [LineupSlot], at date: Date = Date()) {
        commit { _ = GameEngine.setLineup(into: &$0, slots: slots, at: date) }
    }

    @discardableResult
    func undoLast(teamScope: UUID? = nil) -> Bool {
        var undone = false
        commit { undone = GameEngine.undoLast(into: &$0, teamScope: teamScope) }
        return undone
    }

    /// Escape hatch for admin CRUD the engine doesn't own (roster/team/catalog edits).
    /// Still funnels through the same persist-after-mutate path so nothing bypasses saving.
    func apply(_ transform: (inout AppState) -> Void) {
        commit(transform)
    }

    // MARK: - Internals

    private func commit(_ transform: (inout AppState) -> Void) {
        transform(&state)
        do {
            try persistence.save(state)
            saveError = nil
        } catch {
            saveError = "Save failed: \(error)"
        }
    }
}
