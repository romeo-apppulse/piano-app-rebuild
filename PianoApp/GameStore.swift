//
//  GameStore.swift
//  PianoApp
//
//  The one @MainActor bridge between PianoCore's pure engine and SwiftUI.
//
//  Invariants:
//    • `state` is the single source of truth; it is private(set) so views can only
//      change it by calling a method here.
//    • GAMEPLAY mutations funnel through the typed GameEngine methods (attack, adjustHP,
//      setKillTarget, autokill, setLineup, spawn, undo). `apply(_:)` is reserved
//      STRICTLY for roster/team/catalog CRUD the engine does not own.
//    • Every mutation is followed by an atomic save via JSONFilePersistence; a failed
//      save never crashes — it surfaces on `saveError` for the UI to show.
//

import Foundation
import PianoCore

@MainActor
final class GameStore: ObservableObject {
    @Published private(set) var state: AppState
    @Published var saveError: String?
    /// Set once on first launch (or the DEBUG exerciser) if legacy data was migrated.
    @Published private(set) var migrationReport: MigrationReport?

    private let persistence: JSONFilePersistence

    /// The directory monster-art image files live in — the SAME directory this store was
    /// initialized with (Documents in production, a temp dir under UITest/seed fixtures).
    /// Reads (`MonsterArt`) and writes (the picker) must both use THIS, not the static
    /// `documentsDirectory`, or seeded builds would look for art in the wrong sandbox.
    let imageDirectory: URL

    /// First-launch flow (the caller passes the app's Documents dir in production):
    ///   1. If `appState.json` exists → load it.
    ///   2. Else if the old app's legacy files are present → migrate + save + report.
    ///   3. Else → a fresh empty state.
    init(directory: URL = GameStore.documentsDirectory) {
        let persistence = JSONFilePersistence(directory: directory)
        self.persistence = persistence
        self.imageDirectory = directory

        if persistence.exists() {
            do {
                state = try persistence.load()
            } catch {
                state = AppState()
                saveError = "Could not load saved data (\(error)). Started with an empty board; a backup may exist."
            }
        } else if let legacy = LegacyLoader.load(fromDirectory: directory) {
            let (migrated, report) = Migration.migrate(legacy.data, at: Date())
            state = migrated
            var enriched = report
            enriched.notes.append(contentsOf: legacy.warnings)
            migrationReport = enriched
            do { try persistence.save(migrated) }
            catch { saveError = "Migration succeeded but the first save failed: \(error)" }
        } else {
            state = AppState()
        }
    }

    /// Documents directory, guarded — no force-index. Falls back to a temp dir so the
    /// app can still run (in-memory + best-effort save) rather than trap.
    nonisolated static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    // MARK: - Gameplay (TYPED engine methods only — never `apply`)

    func spawnInitialMonster(teamID: UUID, templateID: UUID, at date: Date = Date()) {
        commit { _ = GameEngine.spawnInitialMonster(into: &$0, teamID: teamID, templateID: templateID, at: date) }
    }

    /// Start one team's monster from the lineup (Backdoor "Start from lineup"). Sets the
    /// slot id and advances the pointer so the lineup and the battle stay in lockstep.
    func spawnFromLineup(teamID: UUID, at date: Date = Date()) {
        commit { _ = GameEngine.spawnFromLineup(into: &$0, teamID: teamID, at: date) }
    }

    /// Auto-start every idle team at the beginning of the lineup. Called when the teacher
    /// saves the lineup, so she no longer has to hand-start each team in Backdoor.
    func startIdleTeamsFromLineup(at date: Date = Date()) {
        commit { _ = GameEngine.startIdleTeamsFromLineup(into: &$0, at: date) }
    }

    /// Returns the engine result so the UI can trigger the congrats moment on a kill and
    /// surface rejections (e.g. `.minibossActive`). Persists only on success.
    @discardableResult
    func attack(targetRecordID: UUID, studentID: UUID, amount: Int, at date: Date = Date()) -> Result<AttackResult, EngineError> {
        let outcome = GameEngine.attack(into: &state, targetRecordID: targetRecordID, studentID: studentID, amount: amount, at: date)
        if case .success = outcome { persist() }
        return outcome
    }

    func editMostRecentAttack(teamScope: UUID? = nil, newAmount: Int) {
        commit { _ = GameEngine.editMostRecentAttack(into: &$0, teamScope: teamScope, newAmount: newAmount) }
    }

    /// The only editable/deletable thing in scope (most-recent-only policy), or nil.
    /// Drives the admin "fix the last entry" affordance; same scope logic as undo.
    func mostRecentAttack(teamScope: UUID? = nil) -> AttackAction? {
        GameEngine.mostRecentAttack(in: state, teamScope: teamScope)
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

    // MARK: - Game settings (config, not gameplay — engine-neutral by design)

    /// Edits the persisted GameSettings (default kill targets, min HP, seeding flag).
    /// NOTE: alive monsters are NOT touched — each MonsterRecord froze its own
    /// killTargetWeeks at spawn; these defaults apply to FUTURE spawns/triggers only.
    /// (Per-monster changes go through setKillTarget, which is undoable.)
    func updateSettings(_ transform: (inout GameSettings) -> Void) {
        commit { transform(&$0.settings) }
    }

    // MARK: - Roster / Team / Catalog CRUD (the ONLY callers of `apply`)

    func addStudent(name: String, teamID: UUID?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apply { $0.students.append(Student(name: trimmed, teamID: teamID, createdAt: Date())) }
    }

    func renameStudent(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apply { if let i = $0.students.firstIndex(where: { $0.id == id }) { $0.students[i].name = trimmed } }
    }

    func assignStudent(_ id: UUID, toTeam teamID: UUID?) {
        apply { if let i = $0.students.firstIndex(where: { $0.id == id }) { $0.students[i].teamID = teamID } }
    }

    /// Soft-delete only: history is never destroyed (see Student.isActive).
    func setStudent(_ id: UUID, active: Bool) {
        apply { if let i = $0.students.firstIndex(where: { $0.id == id }) { $0.students[i].isActive = active } }
    }

    func addTeam(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apply { $0.teams.append(Team(name: trimmed)) }
    }

    func renameTeam(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apply { if let i = $0.teams.firstIndex(where: { $0.id == id }) { $0.teams[i].name = trimmed } }
    }

    /// Removes a team and un-assigns its students (their history stays intact).
    func removeTeam(_ id: UUID) {
        apply {
            $0.teams.removeAll { $0.id == id }
            for i in $0.students.indices where $0.students[i].teamID == id { $0.students[i].teamID = nil }
        }
    }

    func addTemplate(name: String, kind: MonsterKind, artist: String?, imageFileName: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apply { $0.monsterCatalog.append(MonsterTemplate(name: trimmed, imageFileName: imageFileName, artist: artist, kind: kind)) }
    }

    func renameTemplate(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apply { if let i = $0.monsterCatalog.firstIndex(where: { $0.id == id }) { $0.monsterCatalog[i].name = trimmed } }
    }

    /// Point a template at (freshly stored) art, or clear it. `fileName` is a bare name in
    /// `imageDirectory`, produced by `MonsterImageStore.store`. Catalog CRUD → `apply` is the
    /// correct channel (not the engine). We never touch image *bytes* here: on replace the
    /// previous file is intentionally left on disk (a `.bak` restore may still reference it).
    func setTemplateImage(_ id: UUID, fileName: String?) {
        apply { if let i = $0.monsterCatalog.firstIndex(where: { $0.id == id }) { $0.monsterCatalog[i].imageFileName = fileName } }
    }

    func removeTemplate(_ id: UUID) {
        // If the lineup still references this template, drop those slots FIRST through
        // the typed engine (undoable) — otherwise the engine would silently skip the
        // orphaned slots. setLineup validates against the catalog, and the surviving
        // slots' templates all still exist at this point, so it passes.
        let cleaned = state.lineup.filter { $0.templateID != id }
        if cleaned.count != state.lineup.count { setLineup(cleaned) }
        apply { $0.monsterCatalog.removeAll { $0.id == id } }
    }

    /// The escape hatch for roster/team/catalog CRUD only. Gameplay must NOT use this —
    /// it goes through the typed engine methods above so undo/log invariants hold.
    func apply(_ transform: (inout AppState) -> Void) {
        commit(transform)
    }

    // MARK: - Reads / derived

    func dailyAverage(for studentID: UUID, now: Date = Date()) -> Double {
        PracticeMath.dailyAverage(forStudent: studentID,
                                  entries: state.combatLog.entries,
                                  now: now,
                                  calendar: state.settings.resolvedCalendar)
    }

    func liveMonster(forTeam teamID: UUID) -> MonsterRecord? {
        state.aliveRegularRecord(forTeam: teamID)
    }

    // MARK: - Backup (export / restore the whole appState)

    func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(state)
    }

    @discardableResult
    func importBackup(_ data: Data) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let imported = try? decoder.decode(AppState.self, from: data) else {
            saveError = "Restore failed: that file is not a valid PianoApp backup."
            return false
        }
        state = imported
        do { try persistence.save(state); saveError = nil; return true }
        catch { saveError = "Restore save failed: \(error)"; return false }
    }

    // MARK: - Internals

    private func commit(_ transform: (inout AppState) -> Void) {
        transform(&state)
        persist()
    }

    private func persist() {
        do {
            try persistence.save(state)
            saveError = nil
        } catch {
            saveError = "Save failed: \(error)"
        }
    }

    #if DEBUG
    /// DEBUG-ONLY migration exerciser. Writes fixture LEGACY json into the DEV sandbox,
    /// clears appState.json, and re-runs the real first-launch migration so the admin
    /// screens have data to show. Never touches the live app's real data — it operates
    /// on this build's own sandbox directory.
    func debugSeedFromSampleLegacyData() {
        DebugFixtures.writeSampleLegacyFiles(to: persistence.directory)
        try? FileManager.default.removeItem(at: persistence.fileURL)
        guard let legacy = LegacyLoader.load(fromDirectory: persistence.directory) else { return }
        let (migrated, report) = Migration.migrate(legacy.data, at: Date())
        state = migrated
        var enriched = report
        enriched.notes.append(contentsOf: legacy.warnings)
        migrationReport = enriched
        do { try persistence.save(migrated); saveError = nil }
        catch { saveError = "Debug seed save failed: \(error)" }
    }

    /// DEBUG-ONLY: wipe back to an empty board (dev sandbox only).
    func debugResetToEmpty() {
        try? FileManager.default.removeItem(at: persistence.fileURL)
        state = AppState()
        migrationReport = nil
        saveError = nil
        try? persistence.save(state)
    }
    #endif
}
