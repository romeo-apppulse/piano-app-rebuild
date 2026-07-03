//
//  LegacyImport.swift — tolerant reader for the OLD app's on-disk data.
//
//  The legacy app persisted four JSON arrays plus one single-object file in its
//  Documents directory, all cross-referenced by NAME STRINGS:
//    monsterDeck.json  [{artist, name, img, damage}]      (StandardMonster, no id)
//    teamDeck.json     [{id?, name, minHP, maxHP}]
//    battleDeck.json   [{id, monsterName, teamName, hp, dmg}]
//    students.json     [{id, name, teamName, score}]
//    MiniBoss.json     {name, img, damage}                 (single object — the legacy
//                       archive() overwrote this file, so only the LAST miniboss survives)
//
//  Parsing is deliberately per-element via JSONSerialization, never all-or-nothing
//  Codable: one malformed element is skipped WITH A WARNING, the rest still import.
//  Nothing here mutates anything — reading only. IMPORTANT: read from a raw copy of
//  the Documents directory, NOT from the app's export blob — MiniBoss.json was never
//  part of the export file list and would be silently missing there.
//

import Foundation

// MARK: - Lenient snapshots of the legacy shapes

public struct LegacyMonster: Equatable {
    public let name: String
    public let img: String?
    public let artist: String?

    public init(name: String, img: String? = nil, artist: String? = nil) {
        self.name = name
        self.img = img
        self.artist = artist
    }
}

public struct LegacyTeam: Equatable {
    public let id: UUID?
    public let name: String

    public init(id: UUID? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

public struct LegacyBattle: Equatable {
    public let monsterName: String
    public let teamName: String
    public let hp: Int
    public let dmg: Int

    public init(monsterName: String, teamName: String, hp: Int, dmg: Int) {
        self.monsterName = monsterName
        self.teamName = teamName
        self.hp = hp
        self.dmg = dmg
    }
}

public struct LegacyStudent: Equatable {
    public let id: UUID?
    public let name: String
    public let teamName: String
    public let score: Int

    public init(id: UUID? = nil, name: String, teamName: String, score: Int) {
        self.id = id
        self.name = name
        self.teamName = teamName
        self.score = score
    }
}

public struct LegacyData: Equatable {
    public var monsters: [LegacyMonster]
    public var teams: [LegacyTeam]
    public var battles: [LegacyBattle]
    public var students: [LegacyStudent]
    public var miniboss: LegacyMonster?

    public init(monsters: [LegacyMonster] = [],
                teams: [LegacyTeam] = [],
                battles: [LegacyBattle] = [],
                students: [LegacyStudent] = [],
                miniboss: LegacyMonster? = nil) {
        self.monsters = monsters
        self.teams = teams
        self.battles = battles
        self.students = students
        self.miniboss = miniboss
    }
}

// MARK: - Loader

public enum LegacyLoader {

    public static let monsterFile = "monsterDeck.json"
    public static let teamFile = "teamDeck.json"
    public static let battleFile = "battleDeck.json"
    public static let studentFile = "students.json"
    public static let minibossFile = "MiniBoss.json"

    /// Reads whatever legacy files exist in `directory`. Returns nil if NONE of them
    /// exist (a fresh install — nothing to migrate). Individual missing files are
    /// fine; malformed files/elements are skipped with warnings.
    public static func load(fromDirectory directory: URL) -> (data: LegacyData, warnings: [String])? {
        func read(_ name: String) -> Data? {
            try? Data(contentsOf: directory.appendingPathComponent(name))
        }
        let raw = [monsterFile: read(monsterFile), teamFile: read(teamFile),
                   battleFile: read(battleFile), studentFile: read(studentFile),
                   minibossFile: read(minibossFile)]
        guard raw.values.contains(where: { $0 != nil }) else { return nil }

        var warnings: [String] = []
        let data = LegacyData(
            monsters: raw[monsterFile].flatMap { $0 }.map { parseMonsters($0, warnings: &warnings) } ?? [],
            teams: raw[teamFile].flatMap { $0 }.map { parseTeams($0, warnings: &warnings) } ?? [],
            battles: raw[battleFile].flatMap { $0 }.map { parseBattles($0, warnings: &warnings) } ?? [],
            students: raw[studentFile].flatMap { $0 }.map { parseStudents($0, warnings: &warnings) } ?? [],
            miniboss: raw[minibossFile].flatMap { $0 }.flatMap { parseMiniboss($0, warnings: &warnings) }
        )
        return (data, warnings)
    }

    // MARK: Per-file parsers (public so tests can feed Data directly)

    public static func parseMonsters(_ data: Data, warnings: inout [String]) -> [LegacyMonster] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            warnings.append("\(monsterFile) is not a JSON array — no monsters imported.")
            return []
        }
        return array.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else {
                warnings.append("\(monsterFile): skipped a monster with no name.")
                return nil
            }
            return LegacyMonster(name: name,
                                 img: dict["img"] as? String,
                                 artist: dict["artist"] as? String)
        }
    }

    public static func parseTeams(_ data: Data, warnings: inout [String]) -> [LegacyTeam] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            warnings.append("\(teamFile) is not a JSON array — no teams imported.")
            return []
        }
        return array.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else {
                warnings.append("\(teamFile): skipped a team with no name.")
                return nil
            }
            let id = (dict["id"] as? String).flatMap(UUID.init(uuidString:))
            return LegacyTeam(id: id, name: name)   // minHP/maxHP deliberately dropped
        }
    }

    public static func parseBattles(_ data: Data, warnings: inout [String]) -> [LegacyBattle] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            warnings.append("\(battleFile) is not a JSON array — no battles imported.")
            return []
        }
        return array.compactMap { dict in
            guard let monsterName = dict["monsterName"] as? String,
                  let teamName = dict["teamName"] as? String,
                  let hp = dict["hp"] as? Int else {
                warnings.append("\(battleFile): skipped a battle missing monsterName/teamName/hp.")
                return nil
            }
            return LegacyBattle(monsterName: monsterName, teamName: teamName,
                                hp: hp, dmg: dict["dmg"] as? Int ?? 0)
        }
    }

    public static func parseStudents(_ data: Data, warnings: inout [String]) -> [LegacyStudent] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            warnings.append("\(studentFile) is not a JSON array — no students imported.")
            return []
        }
        return array.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else {
                warnings.append("\(studentFile): skipped a student with no name.")
                return nil
            }
            return LegacyStudent(id: (dict["id"] as? String).flatMap(UUID.init(uuidString:)),
                                 name: name,
                                 teamName: dict["teamName"] as? String ?? "",
                                 score: dict["score"] as? Int ?? 0)
        }
    }

    public static func parseMiniboss(_ data: Data, warnings: inout [String]) -> LegacyMonster? {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = dict["name"] as? String, !name.isEmpty else {
            warnings.append("\(minibossFile) is malformed — miniboss not imported.")
            return nil
        }
        return LegacyMonster(name: name, img: dict["img"] as? String, artist: nil)
    }
}
