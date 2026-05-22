//
//  BattleDeck.swift
//  PianoAppv2
//
//  Created by Rebecca Jackson on 5/19/25.
//

import Foundation

class TeamDeck: ObservableObject {
    @Published var teams: [Team]

    /// Names of teams whose HP fields were missing/corrupt on disk at load time.
    /// The UI surfaces these to the user so the team can be re-saved with real values.
    /// Populated only at init() — relaunch the app after fixing a team to clear it.
    @Published var recoveredTeamNames: [String] = []

    init() {
        let result = Self.loadTeams(fromFile: "teamDeck.json")
        self.teams = result.teams
        self.recoveredTeamNames = result.recovered
    }

    /// Per-element load: bypass Codable's all-or-nothing for arrays so a single bad
    /// team can't wipe out the whole roster. A team with missing HP is recovered
    /// with a placeholder range AND its name is recorded for the UI to surface.
    private static func loadTeams(fromFile fileName: String) -> (teams: [Team], recovered: [String]) {
        let fileURL = DataStore.documentsURL().appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return ([], []) }

        guard let rawArray = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            print("teamDeck.json is not a JSON array — leaving teams empty")
            return ([], [])
        }

        var teams: [Team] = []
        var recovered: [String] = []

        for dict in rawArray {
            guard let name = dict["name"] as? String, !name.isEmpty else {
                continue
            }

            let id: UUID = {
                if let s = dict["id"] as? String, let u = UUID(uuidString: s) { return u }
                return UUID()
            }()

            if let minHP = dict["minHP"] as? Int,
               let maxHP = dict["maxHP"] as? Int,
               minHP <= maxHP {
                let team = Team(name: name, minHP: minHP, maxHP: maxHP)
                team.id = id
                teams.append(team)
            } else {
                // Placeholder HP that is NOT a plausible-looking value (vs. the old 150/250
                // silent default). The UI flags this team for re-entry.
                let team = Team(name: name, minHP: 1, maxHP: 1)
                team.id = id
                teams.append(team)
                recovered.append(name)
            }
        }
        return (teams, recovered)
    }

    func addTeam(team: Team) {
        teams.append(team)
    }

    func remTeam(team: Team) {
        self.teams.removeAll { $0 === team }
        recoveredTeamNames.removeAll { $0 == team.name }
    }

    func archive() {
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let jsonFilePath = documentsDirectory.appendingPathComponent("teamDeck.json")

        DataStore.rotateBackups(for: jsonFilePath)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let jsonData = try encoder.encode(self.teams)
            try jsonData.write(to: jsonFilePath, options: .atomic)
            print("JSON data was written to the file successfully at: \(jsonFilePath)")

        } catch {
            print("Error while writing to file: \(error.localizedDescription)")
        }
    }
}
