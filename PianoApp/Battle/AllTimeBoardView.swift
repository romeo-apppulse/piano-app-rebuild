//
//  AllTimeBoardView.swift
//  PianoApp
//
//  The all-time cumulative leaderboard (across every monster, incl. day-one seeds),
//  reachable with one gesture from the battle screen. Shared-placement ranking is done
//  in PianoCore (Leaderboards.allTime).
//

import SwiftUI
import PianoCore

struct AllTimeBoardView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    private var rows: [LeaderboardRow] { Leaderboards.allTime(state: store.state) }

    var body: some View {
        NavigationStack {
            List(rows) { row in
                HStack(spacing: 16) {
                    Text(medal(row.rank))
                        .font(.title2.bold().monospacedDigit())
                        .frame(width: 56, alignment: .leading)
                    Text(row.displayName).font(.title3)
                    Spacer()
                    Text("\(row.totalDamage)").font(.title3.bold().monospacedDigit())
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("All-Time")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.bold() }
            }
        }
    }

    private func medal(_ rank: Int) -> String {
        switch rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return "#\(rank)"
        }
    }
}
