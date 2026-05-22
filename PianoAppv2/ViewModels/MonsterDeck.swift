//
//  MonsterDeck.swift
//  PianoAppv2
//
//  Created by Rebecca Jackson on 5/11/25.
//

import Foundation

class MonsterDeck: ObservableObject {
    @Published var monsters: [StandardMonster]
    
    init() {
        func decodeMonsters(fromFile fileName: String) -> [StandardMonster]? {
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
                let monsters = try JSONDecoder().decode([StandardMonster].self, from: jsonData)
                return monsters
            } catch {
                print("Error decoding JSON from file: \(error)")
                return nil
            }
        }
        
        let arr = decodeMonsters(fromFile: "monsterDeck.json") ?? []
        self.monsters = arr
    }
    
    func addMonster(monster: StandardMonster) {
        monsters.append(monster)
    }
    
    func remMonster(monster: StandardMonster) {
        self.monsters.removeAll { $0.name == monster.name }
    }
    
    func archive() {
        // Step 1: Get the path to the Documents directory
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!

        // Step 2: Create a path for the JSON file
        let jsonFilePath = documentsDirectory.appendingPathComponent("monsterDeck.json")

        // Step 3: Encode data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted //readable format
            let jsonData = try encoder.encode(self.monsters)
            
            // Step 5: Write the JSON data to the file in the Documents directory
            try jsonData.write(to: jsonFilePath, options: .atomic)
            print("JSON data was written to the file successfully at: \(jsonFilePath)")
            
        } catch {
            print("Error while writing to file: \(error.localizedDescription)")
        }
    }
    
    func nextMonster(monster: StandardMonster) -> StandardMonster {
        // Fall back to the current monster if the deck is empty or the
        // current monster was deleted mid-battle — prevents force-unwrap crash.
        guard !monsters.isEmpty else { return monster }
        guard let monsterIndex = monsters.firstIndex(of: monster) else { return monsters[0] }
        if monsterIndex + 1 != monsters.count {
            return monsters[monsterIndex + 1]
        } else {
            return monsters[0]
        }
    }
    
}
