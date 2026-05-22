//
//  PianoAppv2Tests.swift
//  PianoAppv2Tests
//
//  Focused regression tests for the bug fixes.
//  Suite is .serialized because tests touch shared Documents files.
//

import Testing
import Foundation
@testable import PianoAppv2

@Suite(.serialized)
struct PianoAppv2Tests {

    init() {
        Self.cleanDocuments()
    }

    // MARK: - Helpers

    static func cleanDocuments() {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bases = ["monsterDeck.json", "teamDeck.json", "battleDeck.json", "students.json", "MiniBoss.json"]
        for name in bases {
            let base = dir.appendingPathComponent(name)
            try? fm.removeItem(at: base)
            try? fm.removeItem(at: base.appendingPathExtension("bak1"))
            try? fm.removeItem(at: base.appendingPathExtension("bak2"))
        }
    }

    private struct Fixture {
        let monsterDeck: MonsterDeck
        let teamDeck: TeamDeck
        let battleDeck: BattleDeck
        let studentDeck: StudentDeck
        let m1: StandardMonster
        let m2: StandardMonster
        let teamA: Team
        let teamB: Team
        let battleA: Battle
        let battleB: Battle
    }

    /// Two teams, two monsters. teamA at index 0, teamB at index 1.
    /// HP is pinned (min == max) for deterministic damage math.
    private func makeFixture(teamAHP: Int = 10, teamBHP: Int = 100) -> Fixture {
        let m1 = StandardMonster(name: "monsterOne", img: "x.png", artist: "A")
        let m2 = StandardMonster(name: "monsterTwo", img: "y.png", artist: "B")
        let monsterDeck = MonsterDeck()
        monsterDeck.monsters = [m1, m2]

        let teamA = Team(name: "TeamA", minHP: teamAHP, maxHP: teamAHP)
        let teamB = Team(name: "TeamB", minHP: teamBHP, maxHP: teamBHP)
        let teamDeck = TeamDeck()
        teamDeck.teams = [teamA, teamB]

        let battleA = Battle(monster: m1, team: teamA)
        let battleB = Battle(monster: m1, team: teamB)
        let battleDeck = BattleDeck(monsterDeck: monsterDeck, teamDeck: teamDeck)
        battleDeck.battles = [battleA, battleB]

        let studentDeck = StudentDeck()
        studentDeck.students = [
            Student(name: "Alice", teamName: "TeamA"),
            Student(name: "Bob",   teamName: "TeamB"),
        ]

        return Fixture(
            monsterDeck: monsterDeck,
            teamDeck: teamDeck,
            battleDeck: battleDeck,
            studentDeck: studentDeck,
            m1: m1, m2: m2,
            teamA: teamA, teamB: teamB,
            battleA: battleA, battleB: battleB
        )
    }

    /// Mirrors the FIXED StandardMonsterView.attack() body verbatim so we can
    /// exercise the logic without instantiating a SwiftUI View (selectedStudent
    /// is private @State inside the View and can't be set externally).
    private func runAttack_fixed(
        attackDmg: Int,
        selectedBattle: inout Battle?,
        selectedStudent: String,
        battleDeck: BattleDeck,
        monsterDeck: MonsterDeck,
        studentDeck: StudentDeck
    ) {
        guard let initialBattle = selectedBattle else { return }
        var battle = initialBattle
        var damage = attackDmg

        if battle.leftoverDmg(damage: damage) >= 0 {
            damage = battle.leftoverDmg(damage: damage)
            // Inlined nextMonster()
            let team = battle.team
            let monster = battle.monster
            battleDeck.remBattle(team: team)
            let nextMonster = monsterDeck.nextMonster(monster: monster)
            let newBattle = Battle(monster: nextMonster, team: team)
            battleDeck.addBattle(battle: newBattle)
            selectedBattle = battleDeck.battles.last
            battle = battleDeck.battles.last!
            studentDeck.resetScores(teamName: battle.team.name)
        }

        if let targetId = selectedBattle?.id,
           let idx = battleDeck.battles.firstIndex(where: { $0.id == targetId }) {
            battleDeck.battles[idx].addDmg(dmg: damage)
        }
        if let studentIdx = studentDeck.indexOf(name: selectedStudent) {
            studentDeck.students[studentIdx].updateScore(num: damage)
        }
    }

    // ========================================================================
    // MARK: - stale-index misroute (the headline crash bug)
    // ========================================================================

    @Test("Killing teamA's battle at index 0 routes leftover damage to the NEW teamA battle, not teamB")
    func attack_killsFirstBattle_leftoverGoesToCorrectNewBattle() throws {
        let f = makeFixture(teamAHP: 10, teamBHP: 100)
        var selected: Battle? = f.battleA

        runAttack_fixed(
            attackDmg: 15,                 // 10 to kill, 5 leftover
            selectedBattle: &selected,
            selectedStudent: "Alice",
            battleDeck: f.battleDeck,
            monsterDeck: f.monsterDeck,
            studentDeck: f.studentDeck
        )

        #expect(f.battleDeck.battles.count == 2)
        let teamBSlot = try #require(f.battleDeck.battles.first { $0.team.id == f.teamB.id })
        let newTeamA = try #require(f.battleDeck.battles.first { $0.team.id == f.teamA.id })

        #expect(teamBSlot.id == f.battleB.id, "TeamB's battle should be the original, untouched")
        #expect(teamBSlot.dmg == 0,           "TeamB must NOT receive TeamA's leftover damage")
        #expect(newTeamA.id != f.battleA.id,  "TeamA should have a freshly spawned battle")
        #expect(newTeamA.dmg == 5,            "New TeamA battle should hold the 5 leftover damage")
        #expect(newTeamA.monster.name == "monsterTwo", "New battle should hold the next monster (m2)")

        #expect(selected?.id == newTeamA.id, "selectedBattle should point at the new TeamA battle")

        // Student score: Alice belongs to TeamA, scores got reset on kill, then +5 leftover credited.
        let alice = try #require(f.studentDeck.students.first { $0.name == "Alice" })
        #expect(alice.score == 5)
    }

    @Test("DEMONSTRATION: OLD stale-index logic misroutes leftover damage to teamB (proves the test exercises the bug)")
    func demo_oldStaleIndexLogic_misroutesDamage() throws {
        let f = makeFixture(teamAHP: 10, teamBHP: 100)
        var selected: Battle? = f.battleA

        // Replay the ORIGINAL buggy logic verbatim.
        let i = f.battleDeck.battles.firstIndex(where: { $0.id == selected!.id })!  // i = 0
        var battle = selected!
        var damage = 15

        if battle.leftoverDmg(damage: damage) >= 0 {
            damage = battle.leftoverDmg(damage: damage)
            let team = battle.team
            let monster = battle.monster
            f.battleDeck.remBattle(team: team)
            let next = f.monsterDeck.nextMonster(monster: monster)
            f.battleDeck.addBattle(battle: Battle(monster: next, team: team))
            selected = f.battleDeck.battles.last
            battle = f.battleDeck.battles.last!
        }

        f.battleDeck.battles[i].addDmg(dmg: damage)  // <-- THE BUG: hits battles[0] which is now teamB

        let slot0 = f.battleDeck.battles[0]
        let slot1 = f.battleDeck.battles[1]
        #expect(slot0.team.id == f.teamB.id, "After remove+append, index 0 is TeamB's battle")
        #expect(slot0.dmg == 5,              "OLD bug: 5 leftover damage incorrectly went to TeamB")
        #expect(slot1.team.id == f.teamA.id, "After remove+append, index 1 is the new TeamA battle")
        #expect(slot1.dmg == 0,              "OLD bug: new TeamA battle received nothing")
    }

    @Test("Exact-kill (leftover = 0) spawns next monster, no damage to it, no damage to other team")
    func attack_exactKill_leftoverZero_spawnsNextWithZeroDamage() throws {
        let f = makeFixture(teamAHP: 10, teamBHP: 100)
        var selected: Battle? = f.battleA

        runAttack_fixed(
            attackDmg: 10, selectedBattle: &selected, selectedStudent: "Alice",
            battleDeck: f.battleDeck, monsterDeck: f.monsterDeck, studentDeck: f.studentDeck
        )

        let newTeamA = try #require(f.battleDeck.battles.first { $0.team.id == f.teamA.id })
        let teamB    = try #require(f.battleDeck.battles.first { $0.team.id == f.teamB.id })
        #expect(newTeamA.dmg == 0)
        #expect(teamB.dmg == 0)
        #expect(newTeamA.monster.name == "monsterTwo")
    }

    @Test("Non-killing attack applies full damage to current battle, no spawn")
    func attack_nonKilling_appliesFullDamageInPlace() throws {
        let f = makeFixture(teamAHP: 100, teamBHP: 100)
        var selected: Battle? = f.battleA

        runAttack_fixed(
            attackDmg: 30, selectedBattle: &selected, selectedStudent: "Alice",
            battleDeck: f.battleDeck, monsterDeck: f.monsterDeck, studentDeck: f.studentDeck
        )

        #expect(f.battleDeck.battles.count == 2)
        #expect(f.battleA.dmg == 30,                "Current battle should have 30 damage")
        #expect(f.battleB.dmg == 0,                 "TeamB battle should be untouched")
        #expect(f.battleA.monster.name == "monsterOne", "Monster should not have changed")
    }

    // ========================================================================
    // MARK: - force-unwrap guards
    // ========================================================================

    @Test("nextMonster on an empty deck returns the passed-in monster (no crash)")
    func nextMonster_emptyDeck_returnsInputAsFallback() {
        let deck = MonsterDeck()
        deck.monsters = []
        let m = StandardMonster(name: "orphan", img: "x", artist: "a")
        let result = deck.nextMonster(monster: m)
        #expect(result.name == "orphan")
    }

    @Test("nextMonster with monster missing from deck returns first deck monster (no crash)")
    func nextMonster_monsterMissing_returnsFirstInDeck() {
        let deck = MonsterDeck()
        let m2 = StandardMonster(name: "m2", img: "x", artist: "a")
        let m3 = StandardMonster(name: "m3", img: "x", artist: "a")
        deck.monsters = [m2, m3]
        let orphan = StandardMonster(name: "notInDeck", img: "x", artist: "a")
        let result = deck.nextMonster(monster: orphan)
        #expect(result.name == "m2")
    }

    @Test("nextMonster cycles to the next monster in order, wrapping at the end")
    func nextMonster_cyclesInOrder() {
        let deck = MonsterDeck()
        let m1 = StandardMonster(name: "m1", img: "x", artist: "a")
        let m2 = StandardMonster(name: "m2", img: "x", artist: "a")
        let m3 = StandardMonster(name: "m3", img: "x", artist: "a")
        deck.monsters = [m1, m2, m3]
        #expect(deck.nextMonster(monster: m1).name == "m2")
        #expect(deck.nextMonster(monster: m2).name == "m3")
        #expect(deck.nextMonster(monster: m3).name == "m1")
    }

    @Test("dmgPercent returns 0 when hp == 0 (no NaN, no inf, no layout crash)")
    func dmgPercent_hpZero_returnsZero() {
        let battle = Battle(monster: StandardMonster(), team: Team(name: "T", minHP: 0, maxHP: 0))
        battle.hp = 0
        battle.dmg = 5
        let p = battle.dmgPercent()
        #expect(p == 0)
        #expect(!p.isNaN)
        #expect(!p.isInfinite)
    }

    @Test("dmgPercent returns the normal ratio when hp > 0")
    func dmgPercent_normalHp_returnsRatio() {
        let battle = Battle(monster: StandardMonster(), team: Team(name: "T", minHP: 100, maxHP: 100))
        battle.hp = 100
        battle.dmg = 25
        #expect(battle.dmgPercent() == 0.25)
    }

    @Test("StudentDeck.indexOf returns nil for an unknown student name")
    func studentIndexOf_missingStudent_returnsNil() {
        let deck = StudentDeck()
        deck.students = [Student(name: "Alice", teamName: "A")]
        #expect(deck.indexOf(name: "Nobody") == nil)
        #expect(deck.indexOf(name: "Alice") == 0)
    }

    @Test("Attack with selectedBattle = nil returns early without crashing or mutating state")
    func attack_nilSelectedBattle_isSafe() {
        let f = makeFixture()
        var selected: Battle? = nil
        runAttack_fixed(
            attackDmg: 10, selectedBattle: &selected, selectedStudent: "Alice",
            battleDeck: f.battleDeck, monsterDeck: f.monsterDeck, studentDeck: f.studentDeck
        )
        #expect(f.battleA.dmg == 0)
        #expect(f.battleB.dmg == 0)
    }

    @Test("Attack with an unknown student name does not crash; battle damage still applies")
    func attack_unknownStudent_isSafe() {
        let f = makeFixture(teamAHP: 100, teamBHP: 100)
        var selected: Battle? = f.battleA
        runAttack_fixed(
            attackDmg: 10, selectedBattle: &selected, selectedStudent: "GhostStudent",
            battleDeck: f.battleDeck, monsterDeck: f.monsterDeck, studentDeck: f.studentDeck
        )
        #expect(f.battleA.dmg == 10, "Battle damage applies even when student lookup misses")
    }

    @Test("Attack that kills when active monster was deleted mid-session does not crash; falls back via nextMonster guard")
    func attack_killWhenActiveMonsterDeleted_doesNotCrash() throws {
        let f = makeFixture(teamAHP: 10, teamBHP: 100)
        // Remove m1 (battleA's monster) from the deck mid-session.
        f.monsterDeck.monsters = [f.m2]

        var selected: Battle? = f.battleA
        runAttack_fixed(
            attackDmg: 50, selectedBattle: &selected, selectedStudent: "Alice",
            battleDeck: f.battleDeck, monsterDeck: f.monsterDeck, studentDeck: f.studentDeck
        )

        let newTeamA = try #require(f.battleDeck.battles.first { $0.team.id == f.teamA.id })
        #expect(newTeamA.monster.name == "monsterTwo", "nextMonster guard should fall back to first available monster")
    }

    // ========================================================================
    // MARK: - Team HP defaults
    // ========================================================================

    @Test("Team encodes and decodes with real HP preserved (round-trip)")
    func team_codable_roundTrip_preservesHP() throws {
        let original = Team(name: "Round", minHP: 75, maxHP: 125)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Team.self, from: data)

        #expect(decoded.name == "Round")
        #expect(decoded.minHP == 75)
        #expect(decoded.maxHP == 125)
        #expect(decoded.id == original.id)
    }

    @Test("Decoding a Team JSON missing minHP THROWS (no silent 150 fallback)")
    func team_decode_missingMinHP_throws() {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Broken",
          "maxHP": 250
        }
        """#.data(using: .utf8)!

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Team.self, from: json)
        }
    }

    @Test("Decoding a Team JSON missing maxHP THROWS (no silent 250 fallback)")
    func team_decode_missingMaxHP_throws() {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Broken",
          "minHP": 150
        }
        """#.data(using: .utf8)!

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Team.self, from: json)
        }
    }

    @Test("Existing data format (id + name + minHP + maxHP) still decodes correctly")
    func team_decode_existingFormat_loadsLiveData() throws {
        let json = #"""
        {
          "id": "12345678-1234-1234-1234-123456789ABC",
          "name": "Monday Team",
          "minHP": 200,
          "maxHP": 400
        }
        """#.data(using: .utf8)!

        let team = try JSONDecoder().decode(Team.self, from: json)
        #expect(team.name == "Monday Team")
        #expect(team.minHP == 200)
        #expect(team.maxHP == 400)
        #expect(team.id == UUID(uuidString: "12345678-1234-1234-1234-123456789ABC"))
    }

    @Test("Team JSON without 'id' still decodes with a synthesized UUID (backward compat for pre-id saves)")
    func team_decode_missingId_synthesizesUUID() throws {
        let json = #"""
        {
          "name": "Legacy",
          "minHP": 50,
          "maxHP": 75
        }
        """#.data(using: .utf8)!

        let team = try JSONDecoder().decode(Team.self, from: json)
        #expect(team.name == "Legacy")
        #expect(team.minHP == 50)
        #expect(team.maxHP == 75)
        _ = team.id  // any UUID, just must not crash
    }

    // ========================================================================
    // MARK: - Atomic write round-trip sanity
    // ========================================================================

    @Test("MonsterDeck.archive() then reload preserves all data")
    func monsterDeck_archiveAndReload() throws {
        let deck = MonsterDeck()
        deck.monsters = [
            StandardMonster(name: "Alpha", img: "img1.png", artist: "Artist A"),
            StandardMonster(name: "Beta",  img: "img2.png", artist: "Artist B"),
        ]
        deck.archive()

        let reloaded = MonsterDeck()
        #expect(reloaded.monsters.count == 2)
        #expect(reloaded.monsters[0].name == "Alpha")
        #expect(reloaded.monsters[0].artist == "Artist A")
        #expect(reloaded.monsters[0].img == "img1.png")
        #expect(reloaded.monsters[1].name == "Beta")
    }

    @Test("TeamDeck.archive() then reload preserves HP ranges and IDs")
    func teamDeck_archiveAndReload() throws {
        let deck = TeamDeck()
        let teamA = Team(name: "Mon", minHP: 100, maxHP: 200)
        let teamB = Team(name: "Tue", minHP: 300, maxHP: 500)
        let aId = teamA.id
        let bId = teamB.id
        deck.teams = [teamA, teamB]
        deck.archive()

        let reloaded = TeamDeck()
        #expect(reloaded.teams.count == 2)
        #expect(reloaded.teams[0].name == "Mon")
        #expect(reloaded.teams[0].minHP == 100)
        #expect(reloaded.teams[0].maxHP == 200)
        #expect(reloaded.teams[0].id == aId)
        #expect(reloaded.teams[1].minHP == 300)
        #expect(reloaded.teams[1].maxHP == 500)
        #expect(reloaded.teams[1].id == bId)
    }

    @Test("StudentDeck.archive() then reload preserves students and scores")
    func studentDeck_archiveAndReload() throws {
        let deck = StudentDeck()
        let s1 = Student(name: "Alice", teamName: "Mon"); s1.score = 42
        let s2 = Student(name: "Bob",   teamName: "Tue"); s2.score = 0
        deck.students = [s1, s2]
        deck.archive()

        let reloaded = StudentDeck()
        #expect(reloaded.students.count == 2)
        #expect(reloaded.students[0].name == "Alice")
        #expect(reloaded.students[0].score == 42)
        #expect(reloaded.students[1].name == "Bob")
        #expect(reloaded.students[1].score == 0)
    }

    @Test("BattleDeck.archive() then reload resolves monster/team by name and preserves dmg/hp")
    func battleDeck_archiveAndReload() throws {
        let m = StandardMonster(name: "Echo", img: "e.png", artist: "E")
        let monsterDeck = MonsterDeck()
        monsterDeck.monsters = [m]
        monsterDeck.archive()

        let teamA = Team(name: "Mon", minHP: 200, maxHP: 200)
        let teamDeck = TeamDeck()
        teamDeck.teams = [teamA]
        teamDeck.archive()

        let battleDeck = BattleDeck(monsterDeck: monsterDeck, teamDeck: teamDeck)
        let battle = Battle(monster: m, team: teamA)
        battle.dmg = 75
        battle.hp = 200
        battleDeck.battles = [battle]
        battleDeck.archive()

        let reloadedMonsters = MonsterDeck()
        let reloadedTeams = TeamDeck()
        let reloadedBattles = BattleDeck(monsterDeck: reloadedMonsters, teamDeck: reloadedTeams)

        #expect(reloadedBattles.battles.count == 1)
        #expect(reloadedBattles.battles[0].dmg == 75)
        #expect(reloadedBattles.battles[0].hp == 200)
        #expect(reloadedBattles.battles[0].monster.name == "Echo")
        #expect(reloadedBattles.battles[0].team.name == "Mon")
    }

    // ========================================================================
    // MARK: - Recover-and-flag for corrupt Team data
    // ========================================================================

    private func writeRawTeamJSON(_ json: String) {
        let url = DataStore.documentsURL().appendingPathComponent("teamDeck.json")
        try? json.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    @Test("Team with missing minHP is RECOVERED (not dropped) and surfaced via recoveredTeamNames")
    func teamDeck_corruptHP_recoversWithPlaceholderAndFlags() throws {
        writeRawTeamJSON(#"""
        [
          { "id": "11111111-1111-1111-1111-111111111111", "name": "GoodTeam", "minHP": 50, "maxHP": 75 },
          { "id": "22222222-2222-2222-2222-222222222222", "name": "BrokenTeam", "maxHP": 250 }
        ]
        """#)

        let deck = TeamDeck()

        #expect(deck.teams.count == 2, "BrokenTeam must NOT have been dropped")
        let good = try #require(deck.teams.first { $0.name == "GoodTeam" })
        let broken = try #require(deck.teams.first { $0.name == "BrokenTeam" })

        #expect(good.minHP == 50)
        #expect(good.maxHP == 75)
        #expect(broken.minHP == 1, "Placeholder, NOT the old silent 150 default")
        #expect(broken.maxHP == 1, "Placeholder, NOT the old silent 250 default")

        #expect(deck.recoveredTeamNames == ["BrokenTeam"])
    }

    @Test("Team with valid HP loads cleanly and is NOT placed in recoveredTeamNames")
    func teamDeck_validData_noRecoveryFlag() throws {
        writeRawTeamJSON(#"""
        [
          { "id": "33333333-3333-3333-3333-333333333333", "name": "Mon", "minHP": 100, "maxHP": 200 }
        ]
        """#)

        let deck = TeamDeck()
        #expect(deck.teams.count == 1)
        #expect(deck.teams[0].minHP == 100)
        #expect(deck.teams[0].maxHP == 200)
        #expect(deck.recoveredTeamNames.isEmpty)
    }

    @Test("Team with inverted HP range (minHP > maxHP) is treated as corrupt and recovered")
    func teamDeck_invertedHP_recovered() throws {
        writeRawTeamJSON(#"""
        [
          { "name": "Inverted", "minHP": 500, "maxHP": 100 }
        ]
        """#)

        let deck = TeamDeck()
        let team = try #require(deck.teams.first)
        #expect(team.minHP == 1)
        #expect(team.maxHP == 1)
        #expect(deck.recoveredTeamNames == ["Inverted"])
    }

    @Test("Team with no name at all is skipped (can't identify it for the user)")
    func teamDeck_missingName_isSkipped() throws {
        writeRawTeamJSON(#"""
        [
          { "minHP": 100, "maxHP": 200 },
          { "name": "OnlyValid", "minHP": 50, "maxHP": 75 }
        ]
        """#)

        let deck = TeamDeck()
        #expect(deck.teams.count == 1)
        #expect(deck.teams[0].name == "OnlyValid")
        #expect(deck.recoveredTeamNames.isEmpty)
    }

    // ========================================================================
    // MARK: - Rolling backup rotation
    // ========================================================================

    @Test("First archive() creates .bak1 if a current file already existed")
    func archive_rotatesCurrentToBak1() throws {
        let deck = TeamDeck()
        deck.teams = [Team(name: "First", minHP: 1, maxHP: 1)]
        deck.archive()  // creates teamDeck.json (no current → no .bak1 yet)

        let url = DataStore.documentsURL().appendingPathComponent("teamDeck.json")
        let bak1 = url.appendingPathExtension("bak1")
        #expect(!FileManager.default.fileExists(atPath: bak1.path),
                "No backup expected yet; nothing was here to back up")

        deck.teams = [Team(name: "Second", minHP: 2, maxHP: 2)]
        deck.archive()  // current → .bak1

        #expect(FileManager.default.fileExists(atPath: bak1.path), ".bak1 must exist after second write")
        let bak1Data = try Data(contentsOf: bak1)
        let bak1String = String(data: bak1Data, encoding: .utf8) ?? ""
        #expect(bak1String.contains("First"), ".bak1 should contain the previous (First) write")
        #expect(!bak1String.contains("Second"), ".bak1 should NOT contain the latest write")
    }

    @Test("Second archive() rotates .bak1 to .bak2 and writes new .bak1")
    func archive_rotatesBak1ToBak2() throws {
        let deck = TeamDeck()

        deck.teams = [Team(name: "Gen1", minHP: 1, maxHP: 1)]
        deck.archive()
        deck.teams = [Team(name: "Gen2", minHP: 2, maxHP: 2)]
        deck.archive()  // Gen1 → .bak1
        deck.teams = [Team(name: "Gen3", minHP: 3, maxHP: 3)]
        deck.archive()  // .bak1 → .bak2, Gen2 → .bak1

        let url = DataStore.documentsURL().appendingPathComponent("teamDeck.json")
        let bak1 = url.appendingPathExtension("bak1")
        let bak2 = url.appendingPathExtension("bak2")

        let bak1Str = String(data: try Data(contentsOf: bak1), encoding: .utf8) ?? ""
        let bak2Str = String(data: try Data(contentsOf: bak2), encoding: .utf8) ?? ""
        let currentStr = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""

        #expect(currentStr.contains("Gen3"))
        #expect(bak1Str.contains("Gen2"))
        #expect(bak2Str.contains("Gen1"))
    }

    @Test("Oldest backup is dropped after three writes — only .bak1 and .bak2 are kept")
    func archive_keepsAtMostTwoBackups() throws {
        let deck = TeamDeck()
        for gen in 1...4 {
            deck.teams = [Team(name: "Gen\(gen)", minHP: gen, maxHP: gen)]
            deck.archive()
        }

        let url = DataStore.documentsURL().appendingPathComponent("teamDeck.json")
        let bak1 = url.appendingPathExtension("bak1")
        let bak2 = url.appendingPathExtension("bak2")
        let bak3 = url.appendingPathExtension("bak3")

        #expect(FileManager.default.fileExists(atPath: bak1.path))
        #expect(FileManager.default.fileExists(atPath: bak2.path))
        #expect(!FileManager.default.fileExists(atPath: bak3.path), "No third backup should exist")

        let bak1Str = String(data: try Data(contentsOf: bak1), encoding: .utf8) ?? ""
        let bak2Str = String(data: try Data(contentsOf: bak2), encoding: .utf8) ?? ""
        #expect(bak1Str.contains("Gen3"))
        #expect(bak2Str.contains("Gen2"))
    }

    // ========================================================================
    // MARK: - Export / Restore round-trip
    // ========================================================================

    @Test("Export then restore round-trips all four decks")
    func backupManager_exportThenRestore_roundTrips() throws {
        // 1. Populate live state and persist.
        let monsterDeck = MonsterDeck()
        monsterDeck.monsters = [StandardMonster(name: "Echo", img: "e.png", artist: "E")]
        monsterDeck.archive()

        let teamDeck = TeamDeck()
        teamDeck.teams = [Team(name: "Mon", minHP: 200, maxHP: 300)]
        teamDeck.archive()

        let studentDeck = StudentDeck()
        let s = Student(name: "Alice", teamName: "Mon"); s.score = 17
        studentDeck.students = [s]
        studentDeck.archive()

        let battleDeck = BattleDeck(monsterDeck: monsterDeck, teamDeck: teamDeck)
        let b = Battle(monster: monsterDeck.monsters[0], team: teamDeck.teams[0])
        b.dmg = 11; b.hp = 250
        battleDeck.battles = [b]
        battleDeck.archive()

        // 2. Build the export blob and wipe live files.
        let exportData = try BackupManager.makeExportData()
        Self.cleanDocuments()

        // Confirm files are actually gone.
        let docs = DataStore.documentsURL()
        for name in DataStore.dataFileNames {
            #expect(!FileManager.default.fileExists(atPath: docs.appendingPathComponent(name).path))
        }

        // 3. Restore from blob.
        try BackupManager.restore(fromData: exportData)

        // 4. Reload decks from disk and confirm everything came back.
        let reloadedMonsters = MonsterDeck()
        let reloadedTeams = TeamDeck()
        let reloadedStudents = StudentDeck()
        let reloadedBattles = BattleDeck(monsterDeck: reloadedMonsters, teamDeck: reloadedTeams)

        #expect(reloadedMonsters.monsters.first?.name == "Echo")
        #expect(reloadedTeams.teams.first?.minHP == 200)
        #expect(reloadedTeams.teams.first?.maxHP == 300)
        #expect(reloadedStudents.students.first?.name == "Alice")
        #expect(reloadedStudents.students.first?.score == 17)
        #expect(reloadedBattles.battles.first?.dmg == 11)
        #expect(reloadedBattles.battles.first?.monster.name == "Echo")
        #expect(reloadedBattles.battles.first?.team.name == "Mon")
    }

    @Test("Restore rotates existing files into .bak1 so a bad restore can be rolled back")
    func backupManager_restore_rotatesExistingFilesToBackup() throws {
        // Seed live data.
        let teamDeck = TeamDeck()
        teamDeck.teams = [Team(name: "BeforeRestore", minHP: 9, maxHP: 9)]
        teamDeck.archive()

        // Build an export with DIFFERENT data, then restore it.
        let altDeck = TeamDeck()
        altDeck.teams = [Team(name: "AfterRestore", minHP: 5, maxHP: 5)]
        altDeck.archive()  // overwrites teamDeck.json with AfterRestore

        let exportData = try BackupManager.makeExportData()

        // Now put the "before" data back in place, then restore the "after" blob.
        teamDeck.teams = [Team(name: "BeforeRestore", minHP: 9, maxHP: 9)]
        teamDeck.archive()

        try BackupManager.restore(fromData: exportData)

        // teamDeck.json now contains AfterRestore; teamDeck.json.bak1 contains BeforeRestore.
        let url = DataStore.documentsURL().appendingPathComponent("teamDeck.json")
        let bak1 = url.appendingPathExtension("bak1")

        let currentStr = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        let bak1Str = String(data: try Data(contentsOf: bak1), encoding: .utf8) ?? ""
        #expect(currentStr.contains("AfterRestore"))
        #expect(bak1Str.contains("BeforeRestore"))
    }

    @Test("Restoring a malformed backup blob throws and leaves live files untouched")
    func backupManager_restore_malformedBlob_throws() throws {
        // Seed known live data.
        let deck = TeamDeck()
        deck.teams = [Team(name: "Sacred", minHP: 42, maxHP: 42)]
        deck.archive()

        let garbage = Data("not a backup file".utf8)
        #expect(throws: (any Error).self) {
            try BackupManager.restore(fromData: garbage)
        }

        // Live file must be unchanged.
        let reloaded = TeamDeck()
        #expect(reloaded.teams.first?.name == "Sacred")
        #expect(reloaded.teams.first?.minHP == 42)
    }

    @Test("Restoring a backup with an unsupported (newer) version throws cleanly")
    func backupManager_restore_unsupportedVersion_throws() throws {
        let json = #"""
        {
          "version": 9999,
          "exportedAt": "2026-05-23T00:00:00Z",
          "files": {}
        }
        """#.data(using: .utf8)!

        #expect(throws: (any Error).self) {
            try BackupManager.restore(fromData: json)
        }
    }

    @Test("Export omits files that don't exist on disk yet (never crashes on a fresh install)")
    func backupManager_export_handlesMissingFiles() throws {
        // Documents is empty (init() wiped everything).
        let data = try BackupManager.makeExportData()
        let payload = try JSONDecoder().decode(BackupManager.ExportPayload.self, from: data)
        #expect(payload.version == 1)
        #expect(payload.files.isEmpty, "Nothing to back up on a fresh install — empty files dict is fine")
    }
}
