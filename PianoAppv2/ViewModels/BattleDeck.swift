//
//  BattleDeck.swift
//  PianoAppv2
//
//  Created by Rebecca Jackson on 5/19/25.
//

import Foundation

class BattleDeck: ObservableObject {
    @Published var battles: [Battle]
    
    init(monsterDeck: MonsterDeck, teamDeck: TeamDeck) {
        func decodeBattles(fromFile fileName: String) -> [Codable_Battle]? {
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
                let battles = try JSONDecoder().decode([Codable_Battle].self, from: jsonData)
                return battles
            } catch {
                print("Error decoding JSON from file: \(error)")
                return nil
            }
        }
        
        let codableBattles = decodeBattles(fromFile: "battleDeck.json") ?? []
        let workingBattles = codableBattles.map{Battle(archivedBattle: $0, monsterDeck: monsterDeck, teamDeck: teamDeck)}
        
        
        
        self.battles = workingBattles
    }
    
    func addBattle(battle: Battle) {
        battles.append(battle)
    }
    
    func remBattle(team: Team) {
        self.battles.removeAll { $0.team == team }
    }
    
    func archive() {
        let codableBattles = self.battles.map{$0.toCodable()}
        
        // Step 1: Get the path to the Documents directory
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!

        // Step 2: Create a path for the JSON file
        let jsonFilePath = documentsDirectory.appendingPathComponent("battleDeck.json")

        DataStore.rotateBackups(for: jsonFilePath)

        // Step 3: Encode data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted //readable format
            let jsonData = try encoder.encode(codableBattles)
            
            // Step 5: Write the JSON data to the file in the Documents directory
            try jsonData.write(to: jsonFilePath, options: .atomic)
            print("JSON data was written to the file successfully at: \(jsonFilePath)")
            
        } catch {
            print("Error while writing to file: \(error.localizedDescription)")
        }
    }
    
    
    
}
