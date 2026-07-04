//
//  UITestSupport.swift
//  PianoApp
//
//  Deterministic fixtures for the XCUITest harness, seeded THROUGH PianoCore state —
//  no production-data code paths anywhere:
//    • Active only when launched with `-uiTestFixture <name>` (set by the UI tests).
//    • Builds a typed AppState via PianoCore and saves it as appState.json into a
//      FRESH temp directory, which GameStore then uses instead of Documents.
//    • Compiled to an inert nil outside DEBUG, so Release builds carry no fixture code.
//
//  Fixture arithmetic (asserted by the tests — keep in sync with BattleFlowUITests):
//    Teams:   Reds (Ann, Ben) — the default-selected first team; Blues (Cara).
//    Catalog: Gremlin (regular), Dragon (regular), Boss King (miniboss).
//    Lineup:  [Dragon, Boss King, Gremlin].
//    Alive:   Reds → Gremlin pinned 30 HP; Blues → Gremlin pinned 100 HP.
//    battleReady:   Reds' pointer = 0 → killing Gremlin spawns Dragon.
//                   Kill by Ann (30 on one day → avg 30; Ben 0) → Dragon HP = 30×3 = 90.
//    minibossReady: Reds' pointer = 1 → killing Gremlin TRIGGERS Boss King.
//                   Miniboss HP = (Ann 30 + Ben 0 + Cara 0) × 6 = 180.
//

import Foundation
import PianoCore

enum UITestSupport {

    /// The store directory override for a UI-test launch; nil in normal runs.
    static func overrideDirectory() -> URL? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-uiTestFixture"),
              arguments.indices.contains(flagIndex + 1) else { return nil }

        let state: AppState
        switch arguments[flagIndex + 1] {
        case "battleReady":   state = battleFixture(redsStartAtMinibossSlot: false)
        case "minibossReady": state = battleFixture(redsStartAtMinibossSlot: true)
        case "empty":         state = AppState()
        default:              return nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONFilePersistence(directory: directory).save(state)
        return directory
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static func battleFixture(redsStartAtMinibossSlot: Bool) -> AppState {
        let reds = Team(name: "Reds", nextLineupIndex: redsStartAtMinibossSlot ? 1 : 0)
        let blues = Team(name: "Blues")

        let now = Date()
        let students = [
            Student(name: "Ann", teamID: reds.id, createdAt: now),
            Student(name: "Ben", teamID: reds.id, createdAt: now),
            Student(name: "Cara", teamID: blues.id, createdAt: now),
        ]

        let gremlin = MonsterTemplate(name: "Gremlin", kind: .regular)
        let dragon = MonsterTemplate(name: "Dragon", kind: .regular)
        let boss = MonsterTemplate(name: "Boss King", kind: .miniboss)

        let lineup = [
            LineupSlot(templateID: dragon.id),   // index 0
            LineupSlot(templateID: boss.id),     // index 1 — the miniboss slot
            LineupSlot(templateID: gremlin.id),  // index 2
        ]

        let ledger = [
            MonsterRecord(templateID: gremlin.id, kind: .regular, teamID: reds.id,
                          spawnedAt: now, spawnSequence: 0, killTargetWeeks: 3,
                          legacyFixedHP: 30),
            MonsterRecord(templateID: gremlin.id, kind: .regular, teamID: blues.id,
                          spawnedAt: now, spawnSequence: 1, killTargetWeeks: 3,
                          legacyFixedHP: 100),
        ]

        return AppState(students: students,
                        teams: [reds, blues],
                        monsterCatalog: [gremlin, dragon, boss],
                        lineup: lineup,
                        ledger: ledger)
    }
    #endif
}
