//
//  AllTimeBoardView.swift
//  PianoApp
//
//  The leaderboards sheet reached from the trophy on the battle screen. Gathers every
//  board in one scrollable place (kept off the kid-facing play surface so it stays
//  uncluttered): practice average (the client's primary board), highest single hit,
//  weekly damage, and weekly team damage. All ranking lives in PianoCore.Leaderboards.
//

import SwiftUI
import PianoCore

struct AllTimeBoardView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    private var now: Date { Date() }

    var body: some View {
        NavigationStack {
            List {
                averageSection
                singleHitSection
                weeklySection
                teamSection
            }
            .navigationTitle("Leaderboards")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.bold() }
            }
        }
    }

    // Practice average — the client's primary board; TOP 5 get medal placements.
    private var averageSection: some View {
        Section {
            let rows = Leaderboards.averageBoard(state: store.state, now: now)
            if rows.isEmpty { Text("No students yet.").foregroundStyle(.secondary) }
            ForEach(rows) { row in
                boardRow(placement: medalPlacement(row.rank), bold: row.rank <= 5,
                         name: row.displayName, value: String(format: "%.1f", row.average))
            }
        } header: {
            Text("Practice Average")
        } footer: {
            Text("Last \(AverageWindow.windowDays) days ÷ days practiced. Extra Points don't count here.")
        }
    }

    private var singleHitSection: some View {
        Section("Highest Single Hit") {
            let rows = Leaderboards.highestSingleHit(state: store.state)
            if rows.isEmpty { Text("No hits yet.").foregroundStyle(.secondary) }
            ForEach(rows) { row in
                boardRow(placement: "\(row.rank).", bold: row.rank == 1,
                         name: row.displayName, value: "\(row.totalDamage)")
            }
        }
    }

    private var weeklySection: some View {
        Section("Weekly Damage (7 days)") {
            let rows = Leaderboards.weeklyDamage(state: store.state, now: now)
            if rows.isEmpty { Text("No students yet.").foregroundStyle(.secondary) }
            ForEach(rows) { row in
                boardRow(placement: "\(row.rank).", bold: row.rank == 1,
                         name: row.displayName, value: "\(row.totalDamage)")
            }
        }
    }

    private var teamSection: some View {
        Section("Team Weekly Damage (7 days)") {
            let rows = Leaderboards.teamWeekly(state: store.state, now: now)
            if rows.isEmpty { Text("No teams yet.").foregroundStyle(.secondary) }
            ForEach(rows) { row in
                boardRow(placement: "\(row.rank).", bold: row.rank == 1,
                         name: row.displayName, value: "\(row.totalDamage)")
            }
        }
    }

    private func boardRow(placement: String, bold: Bool, name: String, value: String) -> some View {
        HStack(spacing: 16) {
            Text(placement)
                .font(.title3.bold().monospacedDigit())
                .frame(width: 56, alignment: .leading)
            Text(name).font(bold ? .title3.bold() : .title3)
            Spacer()
            Text(value).font(.title3.bold().monospacedDigit())
        }
        .padding(.vertical, 2)
    }

    // Spec: TOP 5 get 1st–5th distinctions; everyone below is listed plainly.
    private func medalPlacement(_ rank: Int) -> String {
        switch rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        case 4: return "4th"
        case 5: return "5th"
        default: return ""
        }
    }
}
