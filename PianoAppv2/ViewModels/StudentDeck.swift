//
//  StudentDeck.swift
//  PianoAppv2
//
//  Created by Rebecca Jackson on 5/19/25.
//

import Foundation

class StudentDeck: ObservableObject {
    @Published var students: [Student]
    
    init() {
        func decodeStudents(fromFile fileName: String) -> [Student]? {
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
                let students = try JSONDecoder().decode([Student].self, from: jsonData)
                return students
            } catch {
                print("Error decoding JSON from file: \(error)")
                return nil
            }
        } //end decodeStudents()
        let arr = decodeStudents(fromFile: "students.json") ?? []
        self.students = arr
    } //end initializer
    
    func archive() {
        // Step 1: Get the path to the Documents directory
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!

        // Step 2: Create a path for the JSON file
        let jsonFilePath = documentsDirectory.appendingPathComponent("students.json")

        // Step 3: Encode data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted //readable format
            let jsonData = try encoder.encode(self.students)
            
            // Step 5: Write the JSON data to the file in the Documents directory
            try jsonData.write(to: jsonFilePath, options: .atomic)
            print("JSON data was written to the file successfully at: \(jsonFilePath)")
            
        } catch {
            print("Error while writing to file: \(error.localizedDescription)")
        }
    } //end archive()
    
    func addStudent(name: String, teamName: String) {
        if name != "" && teamName != "" {
            self.students.append(Student(name: name, teamName: teamName))
        }
    } //end addStudent()
    
    func remStudent(name: String) {
        self.students.removeAll { $0.name == name }
    } //end remStudent()
    
    func retStudentsByTeam(team: String) -> [Student] {
        return self.students.filter { $0.teamName == team }
    } //end retStudentsByTeam
    
    func indexOf(name: String) -> Int? {
        return self.students.firstIndex { $0.name == name }
    }
    
    func resetScores(teamName: String) {
        for student in students {
            if student.teamName == teamName {
                student.score = 0
            }
        }
    }
    
} //end class
