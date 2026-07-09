//
//  BattleScreen.swift
//  PianoApp
//
//  The immersive, kid-facing primary surface. Shows the selected team's live monster
//  (or the shared miniboss when one is active), a big-target attack flow, the current-
//  and past-monster boards, the recent combat log, undo, and the congrats moment on a
//  defeat. The teacher reaches admin via the gear.
//

import SwiftUI
import PianoCore

struct BattleScreen: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Binding var showAdmin: Bool

    @State private var selectedTeamID: UUID?
    @State private var showAttack = false
    @State private var showAllTime = false
    @State private var celebrating = false
    @State private var banner: String?

    // MARK: - Derived state

    private var miniboss: MonsterRecord? { store.state.aliveMiniboss }
    private var teams: [Team] { store.state.teams }
    private var currentTeamID: UUID? { selectedTeamID ?? teams.first?.id }

    /// The monster everyone is attacking right now: the miniboss if one is active
    /// (takeover), else the selected team's live regular monster.
    private var target: MonsterRecord? {
        if let miniboss { return miniboss }
        return currentTeamID.flatMap { store.liveMonster(forTeam: $0) }
    }

    private var attackers: [Student] {
        if miniboss != nil { return store.state.activeStudents }
        guard let teamID = currentTeamID else { return [] }
        return store.state.students.filter { $0.isActive && $0.teamID == teamID }
    }

    /// Undo is team-scoped in normal play, global while a miniboss is active.
    private var undoScope: UUID? { miniboss != nil ? nil : currentTeamID }

    private func template(_ record: MonsterRecord) -> MonsterTemplate? {
        store.state.monsterCatalog.first { $0.id == record.templateID }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            if let target {
                battleLayout(target)
            } else {
                emptyState
            }

            if celebrating { CongratsOverlay().transition(.opacity) }
        }
        .overlay(alignment: .top) { minibossBanner }
        .overlay(alignment: .topTrailing) { adminGear }
        .overlay(alignment: .bottom) { rejectionBanner }
        .animation(.default, value: celebrating)
        .sheet(isPresented: $showAttack) {
            if let target {
                AttackSheet(target: target, attackers: attackers, onResolved: handleAttack)
            }
        }
        .sheet(isPresented: $showAllTime) { AllTimeBoardView() }
    }

    /// Two columns side-by-side where there's room (iPad, landscape). On a compact
    /// width (iPhone portrait) the fixed 400pt boards column would shove the battle
    /// column off the left edge — Undo ends up off-screen — so stack the boards
    /// beneath the battle column inside a single scroll view instead.
    @ViewBuilder
    private func battleLayout(_ target: MonsterRecord) -> some View {
        if hSizeClass == .compact {
            ScrollView {
                VStack(spacing: 24) {
                    battleColumn(target)
                    boardsContent(target)
                }
                .padding(28)
            }
        } else {
            HStack(alignment: .top, spacing: 24) {
                battleColumn(target).frame(maxWidth: .infinity)
                boardsColumn(target).frame(width: 400)
            }
            .padding(28)
        }
    }

    // MARK: - Battle column

    private func battleColumn(_ record: MonsterRecord) -> some View {
        VStack(spacing: 18) {
            if miniboss == nil && teams.count > 1 { teamSelector }

            Text(template(record)?.name ?? "Monster")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
                .accessibilityIdentifier("battle.monsterName")
            if let artist = template(record)?.artist, !artist.isEmpty {
                Text(artist).font(.title3).foregroundStyle(.secondary)
            }

            MonsterArt(template: template(record)).frame(maxHeight: 360)

            hpBar(record)

            Button { showAttack = true } label: {
                Label("LOG PRACTICE", systemImage: "flame.fill")
                    .font(.title.bold()).frame(maxWidth: .infinity, minHeight: 84)
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(celebrating || attackers.isEmpty)
            .accessibilityIdentifier("battle.logPractice")

            HStack {
                Button { _ = store.undoLast(teamScope: undoScope) } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward").font(.title3)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("battle.undo")
                Spacer()
                Button { showAllTime = true } label: {
                    Label("All-Time", systemImage: "trophy.fill").font(.title3)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var teamSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(teams) { team in
                    Button { selectedTeamID = team.id } label: {
                        Text(team.name).font(.title3.bold())
                            .padding(.horizontal, 22).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(currentTeamID == team.id ? .accentColor : .gray)
                }
            }
        }
    }

    private func hpBar(_ record: MonsterRecord) -> some View {
        let effective = store.state.effectiveHP(of: record)
        let remaining = store.state.remainingHP(of: record)
        let fraction = effective > 0 ? Double(remaining) / Double(effective) : 0
        return VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.red).frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 30)
            Text("\(remaining) / \(effective) HP").font(.title3.bold().monospacedDigit())
                .accessibilityIdentifier("battle.hp")
        }
    }

    // MARK: - Boards column

    private func boardsColumn(_ record: MonsterRecord) -> some View {
        ScrollView { boardsContent(record) }
    }

    /// The boards' inner content, WITHOUT a scroll view of its own, so it can sit
    /// either in the side column's scroll view (regular width) or in the compact
    /// layout's outer scroll view (iPhone) — never nested.
    private func boardsContent(_ record: MonsterRecord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            boardSection("Leaderboard", rows: Leaderboards.currentMonster(recordID: record.id, state: store.state))

            if !pastBoard.isEmpty {
                snapshotBoard("Last Monster", rows: pastBoard)
            }

            // The defeated miniboss keeps its OWN past slot (client requirement),
            // distinct from the per-team past-monster board above.
            let pastMiniboss = Leaderboards.pastMiniboss(state: store.state)
            if !pastMiniboss.isEmpty {
                snapshotBoard("Last Miniboss", rows: pastMiniboss)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent").font(.title2.bold())
                let entries = recentLog(record)
                if entries.isEmpty {
                    Text("No hits yet.").foregroundStyle(.secondary)
                }
                ForEach(entries.prefix(10)) { entry in
                    Text("\(store.state.displayName(entry.studentID)) does \(entry.amount) dmg to the monster!")
                        .font(.headline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func boardSection(_ title: String, rows: [LeaderboardRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold())
            if rows.isEmpty { Text("No damage yet.").foregroundStyle(.secondary) }
            ForEach(rows) { row in
                HStack {
                    Text(medal(row.rank)).monospacedDigit().frame(width: 44, alignment: .leading)
                    Text(row.displayName)
                    Spacer()
                    Text("\(row.totalDamage)").bold().monospacedDigit()
                }.font(.title3)
            }
        }
    }

    private func snapshotBoard(_ title: String, rows: [LeaderboardSnapshotRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold())
            ForEach(rows) { row in
                HStack {
                    Text("\(row.rank).").monospacedDigit().foregroundStyle(.secondary)
                    Text(row.displayName)
                    Spacer()
                    Text("\(row.totalDamage)").bold().monospacedDigit()
                }.font(.title3)
            }
        }
    }

    private var pastBoard: [LeaderboardSnapshotRow] {
        guard miniboss == nil, let teamID = currentTeamID else { return [] }
        return Leaderboards.pastMonster(forTeam: teamID, state: store.state)
    }

    private func recentLog(_ record: MonsterRecord) -> [CombatLogEntry] {
        store.state.combatLog.entries
            .filter { $0.monsterRecordID == record.id }
            .sorted { $0.sequence > $1.sequence }
    }

    private func medal(_ rank: Int) -> String {
        switch rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return "#\(rank)"
        }
    }

    // MARK: - Overlays / empty state

    private var minibossBanner: some View {
        Group {
            if miniboss != nil {
                Text("⚔️  MINIBOSS — all teams fight together!")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange)
                    .accessibilityIdentifier("battle.minibossBanner")
            }
        }
    }

    private var adminGear: some View {
        Button { showAdmin = true } label: {
            Image(systemName: "gearshape.fill").font(.title)
        }
        .tint(.secondary)
        .padding()
        .accessibilityIdentifier("battle.admin")
    }

    private var rejectionBanner: some View {
        Group {
            if let banner {
                Text(banner)
                    .font(.headline).foregroundStyle(.white)
                    .padding(12).background(.red, in: Capsule())
                    .padding(.bottom, 24)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            if miniboss == nil && teams.count > 1 { teamSelector }
            Image(systemName: "moon.zzz.fill").font(.system(size: 90)).foregroundStyle(.secondary)
            Text(emptyMessage).font(.title2).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { showAdmin = true } label: {
                Label("Open Admin", systemImage: "gearshape.fill").font(.title3.bold())
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var emptyMessage: String {
        if teams.isEmpty { return "No teams yet.\nAdd teams, students and monsters in Admin." }
        return "No monster in play for this team.\nStart one in Admin → Backdoor Controls."
    }

    // MARK: - Attack result

    private func handleAttack(_ result: Result<AttackResult, EngineError>) {
        switch result {
        case .success(let attack):
            guard attack.killed else { return }
            celebrating = true
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                celebrating = false
            }
        case .failure(let error):
            banner = message(for: error)
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                banner = nil
            }
        }
    }

    private func message(for error: EngineError) -> String {
        switch error {
        case .minibossActive: return "A miniboss is active — everyone must fight it first!"
        case .monsterAlreadyDefeated: return "That monster is already defeated."
        default: return "That move couldn't be applied."
        }
    }
}
