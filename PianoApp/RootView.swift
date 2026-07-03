//
//  RootView.swift
//  PianoApp
//
//  Skeleton root for the rebuild. Proves the GameStore ↔ PianoCore wiring and the
//  first-launch/migration path render. The real UI (immersive battle view + teacher
//  NavigationSplitView admin) replaces this in the next step.
//

import SwiftUI
import PianoCore

struct RootView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        NavigationStack {
            List {
                Section("Loaded state") {
                    stat("Students", store.state.students.count)
                    stat("Teams", store.state.teams.count)
                    stat("Monster catalog", store.state.monsterCatalog.count)
                    stat("Lineup slots", store.state.lineup.count)
                    stat("Monster records", store.state.ledger.count)
                    stat("Actions logged", store.state.actions.count)
                    stat("Schema version", store.state.schemaVersion)
                }

                if let report = store.migrationReport {
                    Section("Migration report") {
                        if report.warnings.isEmpty {
                            Label("No warnings", systemImage: "checkmark.seal")
                        } else {
                            ForEach(report.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                            }
                        }
                        ForEach(report.notes, id: \.self) { note in
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                if let saveError = store.saveError {
                    Section("Save error") {
                        Text(saveError).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("PianoApp — rebuild skeleton")
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        LabeledContent(label, value: "\(value)")
    }
}
