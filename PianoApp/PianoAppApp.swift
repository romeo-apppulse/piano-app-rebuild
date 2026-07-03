//
//  PianoAppApp.swift
//  PianoApp — the rebuilt UI on top of the PianoCore engine.
//
//  Separate app target from PianoAppv2 (the legacy app is left untouched and remains
//  the migration data source). GameStore is created once at launch and injected.
//

import SwiftUI

@main
struct PianoAppApp: App {
    @StateObject private var store = GameStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
