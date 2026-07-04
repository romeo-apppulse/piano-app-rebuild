//
//  DebugFixtures.swift
//  PianoApp
//
//  DEBUG-ONLY. Writes a small set of the OLD app's legacy JSON files into a directory
//  so the migration path can be exercised in the simulator without ever touching
//  Rebecca's real data. Compiled out of release builds entirely.
//
//  Legacy shapes (see PianoCore/LegacyImport.swift): teams keyed by name, students
//  reference a team by name string, monsters have no id (identity = name), battles
//  reference monster+team by name.
//

#if DEBUG
import Foundation

enum DebugFixtures {

    static func writeSampleLegacyFiles(to directory: URL) {
        write(teamDeckJSON, "teamDeck.json", in: directory)
        write(studentsJSON, "students.json", in: directory)
        write(monsterDeckJSON, "monsterDeck.json", in: directory)
        write(battleDeckJSON, "battleDeck.json", in: directory)
    }

    private static func write(_ json: String, _ name: String, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? json.data(using: .utf8)?.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static let teamDeckJSON = """
    [
      { "name": "Red Robins", "minHP": 40, "maxHP": 60 },
      { "name": "Blue Jays",  "minHP": 40, "maxHP": 60 }
    ]
    """

    // NOTE: legacy `score` IS damage to the team's CURRENT (alive) monster, so a team's
    // scores must sum to LESS than that monster's HP, and the battle's `dmg` aggregate
    // should match the sum (otherwise migration flags drift). Kept realistic here.
    private static let studentsJSON = """
    [
      { "name": "Ada",  "teamName": "Red Robins", "score": 20 },
      { "name": "Ben",  "teamName": "Red Robins", "score": 15 },
      { "name": "Cleo", "teamName": "Blue Jays",  "score": 45 },
      { "name": "Dan",  "teamName": "Blue Jays",  "score": 10 }
    ]
    """

    private static let monsterDeckJSON = """
    [
      { "name": "Gremlin",  "img": "gremlin.png",  "artist": "J.S. Bach" },
      { "name": "Dragon",   "img": "dragon.png",   "artist": "Beethoven" }
    ]
    """

    private static let battleDeckJSON = """
    [
      { "monsterName": "Gremlin", "teamName": "Red Robins", "hp": 50, "dmg": 35 },
      { "monsterName": "Dragon",  "teamName": "Blue Jays",  "hp": 80, "dmg": 55 }
    ]
    """
}
#endif
