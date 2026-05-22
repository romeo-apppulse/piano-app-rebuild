//
//  BattleDeck.swift
//  PianoAppv2
//
//  Created by Rebecca Jackson on 5/19/25.
//

import Foundation

class TeamDeck: ObservableObject {
    @Published var teams: [Team]
    
    init() {
        func decodeTeams(fromFile fileName: String) -> [Team]? {
            let fileManager = FileManager.default

            // Get the path to the Documents folder
            guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                print("Could not find Documents folder.")
                return nil
            }

            // Append the file name to the Documents URL
            let fileURL = documentsURL.appendingPathComponent(fileName)

            do {
                // Read the contents of the file as Data
                let jsonData = try Data(contentsOf: fileURL)

                // Decode the JSON data
                let teams = try JSONDecoder().decode([Team].self, from: jsonData)
                return teams
            } catch {
                print("Error decoding JSON from file: \(error)")
                return nil
            }
        }
        
        let arr = decodeTeams(fromFile: "teamDeck.json") ?? []
        self.teams = arr
    }
    
    func addTeam(team: Team) {
        teams.append(team)
    }
    
    func remTeam(team: Team) {
        self.teams.removeAll { $0 === team }
    }
    
    func archive() {
        // Step 1: Get the path to the Documents directory
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!

        // Step 2: Create a path for the JSON file
        let jsonFilePath = documentsDirectory.appendingPathComponent("teamDeck.json")

        // Step 3: Encode data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted //readable format
            let jsonData = try encoder.encode(self.teams)
            
            // Step 5: Write the JSON data to the file in the Documents directory
            try jsonData.write(to: jsonFilePath, options: .atomic)
            print("JSON data was written to the file successfully at: \(jsonFilePath)")
            
        } catch {
            print("Error while writing to file: \(error.localizedDescription)")
        }
    }
}
