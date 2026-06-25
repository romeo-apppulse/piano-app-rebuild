//
//  PersistenceTests.swift — atomic single-file save/load and rolling-backup rotation.
//  These tests touch the filesystem, using a fresh temp directory per test.
//

import XCTest
@testable import PianoCore

final class PersistenceTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pianocore-persist-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func ts(_ s: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }

    /// A non-trivial state (entry + an attack action carrying a defeat outcome with a
    /// frozen board and a spawned successor) so the round-trip exercises the enum
    /// action history, nested records, and dictionaries — all whole-second dates so
    /// the iso8601 round-trip is exact.
    private func sampleState() -> AppState {
        let team = UUID(); let stu = UUID(); let tpl1 = UUID(); let tpl2 = UUID(); let mon = UUID()
        var state = AppState(
            students: [Student(id: stu, name: "Ann", teamID: team, createdAt: ts(0))],
            teams: [Team(id: team, name: "Reds")],
            monsterCatalog: [
                MonsterTemplate(id: tpl1, name: "M1", kind: .regular),
                MonsterTemplate(id: tpl2, name: "M2", kind: .regular),
            ],
            ledger: [MonsterRecord(id: mon, templateID: tpl1, kind: .regular, teamID: team,
                                   spawnedAt: ts(0), spawnSequence: 0, killTargetWeeks: 3, legacyFixedHP: 5)]
        )
        _ = try! GameEngine.attack(into: &state, targetRecordID: mon, studentID: stu, amount: 5, at: ts(10)).get()
        return state
    }

    func testSaveLoadRoundTripsExactly() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFilePersistence(directory: dir)
        let original = sampleState()

        XCTAssertFalse(store.exists())
        try store.save(original)
        XCTAssertTrue(store.exists())

        let loaded = try store.load()
        XCTAssertEqual(loaded, original)
    }

    func testLoadMissingFileThrowsFileNotFound() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFilePersistence(directory: dir)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? PersistenceError, .fileNotFound)
        }
    }

    func testBackupRotationKeepsCurrentPlusTwoAndDropsOldest() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFilePersistence(directory: dir, backupDepth: 2)

        func state(version v: Int) -> AppState { var s = AppState(); s.schemaVersion = v; return s }
        func decodeVersion(_ name: String) throws -> Int {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            return try decoder.decode(AppState.self, from: data).schemaVersion
        }

        try store.save(state(version: 1)) // A
        try store.save(state(version: 2)) // B
        try store.save(state(version: 3)) // C
        // current = C(3), bak1 = B(2), bak2 = A(1)
        XCTAssertEqual(try store.load().schemaVersion, 3)
        XCTAssertEqual(try decodeVersion("appState.json.bak1"), 2)
        XCTAssertEqual(try decodeVersion("appState.json.bak2"), 1)

        try store.save(state(version: 4)) // D → oldest (A) dropped
        // current = D(4), bak1 = C(3), bak2 = B(2)
        XCTAssertEqual(try store.load().schemaVersion, 4)
        XCTAssertEqual(try decodeVersion("appState.json.bak1"), 3)
        XCTAssertEqual(try decodeVersion("appState.json.bak2"), 2)
    }
}
