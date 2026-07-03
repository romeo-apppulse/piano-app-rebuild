//
//  RosterView.swift
//  PianoApp
//
//  Add / rename / reassign / soft-delete students. Soft-delete keeps history (isActive
//  = false) — students are never destroyed.
//

import SwiftUI
import PianoCore

struct RosterView: View {
    @EnvironmentObject private var store: GameStore

    @State private var newName = ""
    @State private var newTeamID: UUID?

    private var active: [Student] { store.state.students.filter { $0.isActive } }
    private var inactive: [Student] { store.state.students.filter { !$0.isActive } }

    var body: some View {
        List {
            Section("Add student") {
                TextField("Name", text: $newName)
                    .font(.title3)
                Picker("Team", selection: $newTeamID) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.state.teams) { team in
                        Text(team.name).tag(UUID?.some(team.id))
                    }
                }
                Button {
                    store.addStudent(name: newName, teamID: newTeamID)
                    newName = ""
                } label: {
                    Label("Add Student", systemImage: "plus.circle.fill").font(.title3.bold())
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section("Active (\(active.count))") {
                if active.isEmpty { Text("No active students").foregroundStyle(.secondary) }
                ForEach(active) { student in
                    NavigationLink { StudentEditorView(studentID: student.id) } label: { row(student) }
                }
            }

            if !inactive.isEmpty {
                Section("Removed (\(inactive.count))") {
                    ForEach(inactive) { student in
                        NavigationLink { StudentEditorView(studentID: student.id) } label: {
                            row(student).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Roster")
    }

    private func row(_ student: Student) -> some View {
        HStack {
            Text(student.name).font(.title3)
            Spacer()
            Text(teamName(student.teamID)).foregroundStyle(.secondary)
        }
    }

    private func teamName(_ id: UUID?) -> String {
        guard let id else { return "Unassigned" }
        return store.state.teams.first { $0.id == id }?.name ?? "Unassigned"
    }
}

/// Detail editor for a single student (rename, reassign team, activate/deactivate).
struct StudentEditorView: View {
    @EnvironmentObject private var store: GameStore
    let studentID: UUID

    @State private var name = ""
    @State private var teamID: UUID?
    @State private var loaded = false

    private var student: Student? { store.state.students.first { $0.id == studentID } }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name).font(.title3)
                    .onSubmit { store.renameStudent(studentID, to: name) }
                Button("Save name") { store.renameStudent(studentID, to: name) }
            }
            Section("Team") {
                Picker("Team", selection: $teamID) {
                    Text("Unassigned").tag(UUID?.none)
                    ForEach(store.state.teams) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .onChange(of: teamID) { newValue in store.assignStudent(studentID, toTeam: newValue) }
            }
            Section {
                if student?.isActive == true {
                    Button(role: .destructive) {
                        store.setStudent(studentID, active: false)
                    } label: { Label("Remove (keep history)", systemImage: "person.badge.minus") }
                } else {
                    Button {
                        store.setStudent(studentID, active: true)
                    } label: { Label("Restore student", systemImage: "person.badge.plus") }
                }
            }
        }
        .navigationTitle(student?.name ?? "Student")
        .onAppear {
            guard !loaded, let student else { return }
            name = student.name
            teamID = student.teamID
            loaded = true
        }
    }
}
