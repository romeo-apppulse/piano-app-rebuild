//
//  TeamsView.swift
//  PianoApp
//
//  Add / rename / delete teams. Deleting a team un-assigns its students (history kept).
//

import SwiftUI
import PianoCore

struct TeamsView: View {
    @EnvironmentObject private var store: GameStore
    @State private var newName = ""

    var body: some View {
        List {
            Section("Add team") {
                TextField("Team name", text: $newName).font(.title3)
                Button {
                    store.addTeam(name: newName)
                    newName = ""
                } label: {
                    Label("Add Team", systemImage: "plus.circle.fill").font(.title3.bold())
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section("Teams (\(store.state.teams.count))") {
                if store.state.teams.isEmpty { Text("No teams yet").foregroundStyle(.secondary) }
                ForEach(store.state.teams) { team in
                    NavigationLink { TeamEditorView(teamID: team.id) } label: {
                        HStack {
                            Text(team.name).font(.title3)
                            Spacer()
                            Text("\(memberCount(team.id)) students").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Teams")
    }

    private func memberCount(_ teamID: UUID) -> Int {
        store.state.students.filter { $0.teamID == teamID && $0.isActive }.count
    }
}

struct TeamEditorView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    let teamID: UUID

    @State private var name = ""
    @State private var loaded = false
    @State private var confirmingDelete = false

    private var team: Team? { store.state.teams.first { $0.id == teamID } }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Team name", text: $name).font(.title3)
                Button("Save name") { store.renameTeam(teamID, to: name) }
            }
            Section {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete team", systemImage: "trash")
                }
            }
        }
        .navigationTitle(team?.name ?? "Team")
        .onAppear { if !loaded, let team { name = team.name; loaded = true } }
        .confirmationDialog("Delete this team? Its students stay but become unassigned.",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete team", role: .destructive) {
                store.removeTeam(teamID)
                dismiss()
            }
        }
    }
}
