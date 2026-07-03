//
//  AveragesView.swift
//  PianoApp
//
//  Read-only view of each active student's rolling daily average — the teacher's
//  practice-trend view. Computed live from the combat log via PracticeMath.dailyAverage
//  (the single source of that definition).
//

import SwiftUI
import PianoCore

struct AveragesView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        List {
            Section {
                Text("Daily average = live damage in the last \(AverageWindow.windowDays) days ÷ distinct days practiced.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            ForEach(store.state.teams) { team in
                let members = activeMembers(team.id)
                if !members.isEmpty {
                    Section(team.name) {
                        ForEach(members) { student in row(student) }
                    }
                }
            }

            let unassigned = store.state.students.filter { $0.isActive && $0.teamID == nil }
            if !unassigned.isEmpty {
                Section("Unassigned") { ForEach(unassigned) { row($0) } }
            }
        }
        .navigationTitle("Daily Averages")
    }

    private func activeMembers(_ teamID: UUID) -> [Student] {
        store.state.students.filter { $0.isActive && $0.teamID == teamID }
    }

    private func row(_ student: Student) -> some View {
        HStack {
            Text(student.name).font(.title3)
            Spacer()
            Text(formatted(store.dailyAverage(for: student.id)))
                .font(.title3.monospacedDigit().weight(.semibold))
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
