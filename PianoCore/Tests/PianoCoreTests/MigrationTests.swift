//
//  MigrationTests.swift — legacy import + migration mapping. Mostly pure; one test
//  exercises the directory loader against temp files.
//

import XCTest
@testable import PianoCore

final class MigrationTests: XCTestCase {

    private func t(_ s: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }

    // MARK: - Mapping

    func testCleanMigrationReusesIDsLinksByNameAndPinsHP() {
        let teamID = UUID(); let studentID = UUID()
        let legacy = LegacyData(
            monsters: [LegacyMonster(name: "Dragon", img: "dragon.jpg", artist: "Bach")],
            teams: [LegacyTeam(id: teamID, name: "Reds")],
            battles: [LegacyBattle(monsterName: "Dragon", teamName: "Reds", hp: 180, dmg: 30)],
            students: [LegacyStudent(id: studentID, name: "Ann", teamName: "Reds", score: 30)]
        )

        let (state, report) = Migration.migrate(legacy, at: t(1000))

        // Ids reused, joins resolved by name into stable-UUID FKs.
        XCTAssertEqual(state.teams.first?.id, teamID)
        XCTAssertEqual(state.students.first?.id, studentID)
        XCTAssertEqual(state.students.first?.teamID, teamID)
        XCTAssertEqual(state.students.first?.createdAt, t(1000))

        // Catalog: minted UUID, art carried over.
        XCTAssertEqual(state.monsterCatalog.count, 1)
        XCTAssertEqual(state.monsterCatalog.first?.imageFileName, "dragon.jpg")
        XCTAssertEqual(state.monsterCatalog.first?.kind, .regular)

        // In-flight battle: alive record pinned to legacy HP; averages empty.
        let record = state.aliveRegularRecord(forTeam: teamID)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.legacyFixedHP, 180)
        XCTAssertEqual(state.effectiveHP(of: record!), 180)
        XCTAssertTrue(record!.spawnAverages.isEmpty)

        // Seed matches the old battle total → no drift warning.
        XCTAssertEqual(state.damageDealt(toMonster: record!.id), 30)
        XCTAssertTrue(report.warnings.isEmpty, "unexpected warnings: \(report.warnings)")
    }

    func testSeedsFeedLeaderboardsButNotAverages() {
        let legacy = LegacyData(
            monsters: [LegacyMonster(name: "Dragon")],
            teams: [LegacyTeam(name: "Reds")],
            battles: [LegacyBattle(monsterName: "Dragon", teamName: "Reds", hp: 100, dmg: 25)],
            students: [LegacyStudent(name: "Ann", teamName: "Reds", score: 25)]
        )
        let (state, _) = Migration.migrate(legacy, at: t(1000))
        let student = state.students[0]

        // Boards see the seed…
        XCTAssertEqual(Leaderboards.allTime(state: state).first?.totalDamage, 25)
        let record = state.ledger[0]
        XCTAssertEqual(Leaderboards.currentMonster(recordID: record.id, state: state).first?.totalDamage, 25)

        // …the daily average does not (origin == .migration is excluded).
        let avg = PracticeMath.dailyAverage(forStudent: student.id,
                                            entries: state.combatLog.entries,
                                            now: t(1000),
                                            calendar: state.settings.resolvedCalendar)
        XCTAssertEqual(avg, 0)
    }

    func testSeedingFlagOffStartsBlank() {
        let legacy = LegacyData(
            monsters: [LegacyMonster(name: "Dragon")],
            teams: [LegacyTeam(name: "Reds")],
            battles: [LegacyBattle(monsterName: "Dragon", teamName: "Reds", hp: 100, dmg: 25)],
            students: [LegacyStudent(name: "Ann", teamName: "Reds", score: 25)]
        )
        let (state, _) = Migration.migrate(legacy, at: t(1000),
                                           settings: GameSettings(seedLeaderboardsFromLegacyScore: false))
        XCTAssertTrue(state.combatLog.entries.isEmpty)
        XCTAssertEqual(state.remainingHP(of: state.ledger[0]), 100) // full bar
    }

    func testOrphansAndCollisionsAreFlaggedNeverPlaceholdered() {
        let legacy = LegacyData(
            monsters: [LegacyMonster(name: "Dragon")],
            teams: [LegacyTeam(name: "Reds"), LegacyTeam(name: "Reds")],   // duplicate name
            battles: [
                LegacyBattle(monsterName: "Ghost", teamName: "Blues", hp: 50, dmg: 0), // unknown both
                LegacyBattle(monsterName: "Dragon", teamName: "Reds", hp: 60, dmg: 0), // ambiguous team
            ],
            students: [
                LegacyStudent(name: "Ann", teamName: "Blues", score: 10),  // unknown team
                LegacyStudent(name: "Bob", teamName: "Reds", score: 10),   // ambiguous team
            ]
        )
        let (state, report) = Migration.migrate(legacy, at: t(1000))

        // Both teams imported (data preserved) but the ambiguous name links nothing.
        XCTAssertEqual(state.teams.count, 2)
        XCTAssertNil(state.students[0].teamID)
        XCTAssertNil(state.students[1].teamID)
        XCTAssertTrue(state.ledger.isEmpty)                 // no battle silently attached
        XCTAssertTrue(state.combatLog.entries.isEmpty)      // seeds skipped (flagged)
        XCTAssertGreaterThanOrEqual(report.warnings.count, 4)
    }

    func testDriftBetweenScoresAndBattleTotalIsFlagged() {
        let legacy = LegacyData(
            monsters: [LegacyMonster(name: "Dragon")],
            teams: [LegacyTeam(name: "Reds")],
            battles: [LegacyBattle(monsterName: "Dragon", teamName: "Reds", hp: 100, dmg: 99)],
            students: [LegacyStudent(name: "Ann", teamName: "Reds", score: 25)]   // 25 ≠ 99
        )
        let (state, report) = Migration.migrate(legacy, at: t(1000))
        XCTAssertEqual(state.damageDealt(toMonster: state.ledger[0].id), 25) // scores trusted
        XCTAssertTrue(report.warnings.contains { $0.contains("differs from the old battle total") })
    }

    func testMinibossFileBecomesMinibossTemplate() {
        let legacy = LegacyData(monsters: [LegacyMonster(name: "Dragon")],
                                miniboss: LegacyMonster(name: "BigBoss", img: "boss.jpg"))
        let (state, _) = Migration.migrate(legacy, at: t(1000))
        let miniboss = state.monsterCatalog.first { $0.kind == .miniboss }
        XCTAssertEqual(miniboss?.name, "BigBoss")
        XCTAssertEqual(miniboss?.imageFileName, "boss.jpg")
    }

    // MARK: - Parsing (legacy JSON shapes)

    func testParsersReadLegacyShapesAndSkipMalformedElements() {
        var warnings: [String] = []

        let monsters = LegacyLoader.parseMonsters(Data("""
        [{"artist":"Bach","name":"Dragon","img":"d.jpg","damage":40},
         {"img":"broken.jpg","damage":1}]
        """.utf8), warnings: &warnings)
        XCTAssertEqual(monsters, [LegacyMonster(name: "Dragon", img: "d.jpg", artist: "Bach")])

        let id = UUID()
        let teams = LegacyLoader.parseTeams(Data("""
        [{"id":"\(id.uuidString)","name":"Reds","minHP":150,"maxHP":250},
         {"name":"Blues","minHP":1,"maxHP":2}]
        """.utf8), warnings: &warnings)
        XCTAssertEqual(teams, [LegacyTeam(id: id, name: "Reds"), LegacyTeam(name: "Blues")])

        let battles = LegacyLoader.parseBattles(Data("""
        [{"id":"\(UUID().uuidString)","monsterName":"Dragon","teamName":"Reds","hp":180,"dmg":30},
         {"monsterName":"NoHP","teamName":"Reds"}]
        """.utf8), warnings: &warnings)
        XCTAssertEqual(battles, [LegacyBattle(monsterName: "Dragon", teamName: "Reds", hp: 180, dmg: 30)])

        let students = LegacyLoader.parseStudents(Data("""
        [{"id":"\(id.uuidString)","name":"Ann","teamName":"Reds","score":30}]
        """.utf8), warnings: &warnings)
        XCTAssertEqual(students, [LegacyStudent(id: id, name: "Ann", teamName: "Reds", score: 30)])

        XCTAssertEqual(LegacyLoader.parseMiniboss(Data("""
        {"name":"BigBoss","img":"b.jpg","damage":0}
        """.utf8), warnings: &warnings), LegacyMonster(name: "BigBoss", img: "b.jpg"))

        XCTAssertEqual(warnings.count, 2) // the nameless monster + the hp-less battle
    }

    func testLoaderReadsDirectoryAndReturnsNilWhenNoLegacyFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pianocore-legacy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(LegacyLoader.load(fromDirectory: dir)) // fresh install → nothing

        try Data("""
        [{"name":"Ann","teamName":"Reds","score":5,"id":"\(UUID().uuidString)"}]
        """.utf8).write(to: dir.appendingPathComponent(LegacyLoader.studentFile))

        let loaded = LegacyLoader.load(fromDirectory: dir)
        XCTAssertEqual(loaded?.data.students.count, 1)
        XCTAssertEqual(loaded?.data.students.first?.name, "Ann")
        XCTAssertTrue(loaded?.data.teams.isEmpty ?? false)  // missing files are fine
    }
}
