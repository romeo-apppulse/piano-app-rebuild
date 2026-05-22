//
//  DataStore.swift
//  PianoAppv2
//
//  Shared persistence helpers: filename source-of-truth + rolling backup rotation.
//

import Foundation

enum DataStore {

    /// All live JSON files the app persists in Documents. Single source of truth
    /// so backup/restore and rotation stay in sync with deck archive() calls.
    static let dataFileNames: [String] = [
        "monsterDeck.json",
        "teamDeck.json",
        "battleDeck.json",
        "students.json",
    ]

    static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Rolls fileURL → .bak1 → .bak2 (oldest dropped) before a write. Best-effort:
    /// any error here is swallowed so the caller's write still proceeds. The point
    /// is to keep the previous 2 good copies around, never to block the live save.
    static func rotateBackups(for fileURL: URL) {
        let fm = FileManager.default
        let bak1 = fileURL.appendingPathExtension("bak1")
        let bak2 = fileURL.appendingPathExtension("bak2")

        try? fm.removeItem(at: bak2)
        if fm.fileExists(atPath: bak1.path) {
            try? fm.moveItem(at: bak1, to: bak2)
        }
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.copyItem(at: fileURL, to: bak1)
        }
    }
}
