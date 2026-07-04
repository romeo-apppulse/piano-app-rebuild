//
//  PianoAppApp.swift
//  PianoApp — the rebuilt UI on top of the PianoCore engine.
//
//  Separate app target from PianoAppv2 (the legacy app is left untouched and remains
//  the migration data source). GameStore is created once at launch and injected.
//
//  UI tests launch with `-uiTestFixture <name>`, which points the store at a fresh
//  temp directory seeded with a deterministic fixture (DEBUG builds only) — the real
//  Documents directory is never involved in a test run.
//

import SwiftUI

@main
struct PianoAppApp: App {
    @StateObject private var store = GameStore(
        directory: UITestSupport.overrideDirectory() ?? GameStore.documentsDirectory
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
