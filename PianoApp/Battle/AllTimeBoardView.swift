//
//  AllTimeBoardView.swift
//  PianoApp
//
//  The all-time board, ranked by each active student's practice AVERAGE (the same number
//  the Daily Averages page shows) — the client's clarified request, replacing cumulative
//  total damage. Shared-placement ranking is done in PianoCore (Leaderboards.averageBoard).
//

import SwiftUI
import PianoCore

struct AllTimeBoardView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    private var rows: [Leaderboards.AverageLeaderboardRow] {
        Leaderboards.averageBoard(state: store.state, now: Date())
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Ranked by practice average (last \(AverageWindow.windowDays) days ÷ days practiced) — the same number as the Daily Averages page.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    HStack(spacing: 16) {
                        // Spec: TOP 5 get 1st–5th place distinctions; everyone below is
                        // listed plainly, with NO rank marker.
                        Text(placement(row.rank))
                            .font(.title2.bold().monospacedDigit())
                            .frame(width: 64, alignment: .leading)
                        Text(row.displayName)
                            .font(row.rank <= 5 ? .title3.bold() : .title3)
                        Spacer()
                        Text(String(format: "%.1f", row.average))
                            .font(.title3.bold().monospacedDigit())
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("All-Time Averages")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.bold() }
            }
        }
    }

    private func placement(_ rank: Int) -> String {
        switch rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        case 4: return "4th"
        case 5: return "5th"
        default: return ""   // no distinction below 5th (spec)
        }
    }
}
