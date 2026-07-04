//
//  AdminRootView.swift
//  PianoApp
//
//  The teacher admin, presented over the battle screen. NavigationSplitView sidebar
//  (roster, teams, catalog, lineup, averages, backdoor, backup) + a DEBUG seeder bar.
//

import SwiftUI

struct AdminRootView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    @State private var section: AdminSection? = .roster

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(AdminSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .font(.title3.weight(.semibold))
                        .padding(.vertical, 6)
                        .tag(section)
                }
            }
            .navigationTitle("Teacher Admin")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.bold()
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
        } detail: {
            NavigationStack { detail(for: section ?? .roster) }
        }
    }

    @ViewBuilder
    private func detail(for section: AdminSection) -> some View {
        switch section {
        case .roster:   RosterView()
        case .teams:    TeamsView()
        case .catalog:  CatalogView()
        case .lineup:   LineupView()
        case .averages: AveragesView()
        case .backdoor: BackdoorView()
        case .backup:   BackupView()
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 8) {
            if let saveError = store.saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red).lineLimit(2)
            }
            #if DEBUG
            DebugBar()
            #endif
        }
        .padding(.horizontal).padding(.bottom, 8)
    }
}

#if DEBUG
/// DEBUG-only controls to exercise the migration path with sample legacy data.
private struct DebugBar: View {
    @EnvironmentObject private var store: GameStore
    var body: some View {
        HStack(spacing: 8) {
            Button { store.debugSeedFromSampleLegacyData() } label: {
                Label("Seed legacy", systemImage: "tray.and.arrow.down.fill")
            }
            Button(role: .destructive) { store.debugResetToEmpty() } label: {
                Label("Reset", systemImage: "trash")
            }
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.bordered)
    }
}
#endif
