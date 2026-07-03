//
//  BackdoorView.swift
//  PianoApp
//
//  Teacher admin controls on the selected team's LIVE monster. All three are TYPED,
//  undoable engine actions: adjust HP (±, no log entry), change kill-target (auto
//  recalculates HP), and autokill (ends the monster, spawns the successor).
//

import SwiftUI
import PianoCore

struct BackdoorView: View {
    @EnvironmentObject private var store: GameStore

    @State private var teamID: UUID?
    @State private var spawnTemplateID: UUID?
    @State private var confirmingAutokill = false

    private var selectedTeam: Team? { store.state.teams.first { $0.id == teamID } }
    private var live: MonsterRecord? { teamID.flatMap { store.liveMonster(forTeam: $0) } }

    var body: some View {
        List {
            Section("Team") {
                Picker("Team", selection: $teamID) {
                    Text("Choose a team").tag(UUID?.none)
                    ForEach(store.state.teams) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }

            if let record = live {
                monsterStats(record)
                hpControls(record)
                killTargetControls(record)
                autokillControl(record)
            } else if selectedTeam != nil {
                spawnControls
            }
        }
        .navigationTitle("Backdoor Controls")
    }

    // MARK: - Live monster

    private func monsterStats(_ record: MonsterRecord) -> some View {
        Section("Current monster") {
            LabeledContent("Name", value: templateName(record.templateID))
            LabeledContent("Effective HP", value: "\(store.state.effectiveHP(of: record))")
            LabeledContent("Damage dealt", value: "\(store.state.damageDealt(toMonster: record.id))")
            LabeledContent("Remaining HP") {
                Text("\(store.state.remainingHP(of: record))").font(.title3.bold().monospacedDigit())
            }
        }
    }

    private func hpControls(_ record: MonsterRecord) -> some View {
        Section("Adjust HP (no log entry)") {
            HStack(spacing: 10) {
                ForEach([-10, -5, -1, 1, 5, 10], id: \.self) { delta in
                    Button(delta > 0 ? "+\(delta)" : "\(delta)") {
                        store.adjustHP(recordID: record.id, delta: delta)
                    }
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                    .tint(delta > 0 ? .green : .red)
                }
            }
            Text("Backdoor offset: \(record.backdoorHPDelta >= 0 ? "+" : "")\(record.backdoorHPDelta)")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func killTargetControls(_ record: MonsterRecord) -> some View {
        Section("Kill target") {
            Stepper("Kill target: \(record.killTargetWeeks) week\(record.killTargetWeeks == 1 ? "" : "s")",
                    onIncrement: { store.setKillTarget(recordID: record.id, weeks: record.killTargetWeeks + 1) },
                    onDecrement: { if record.killTargetWeeks > 1 { store.setKillTarget(recordID: record.id, weeks: record.killTargetWeeks - 1) } })
                .font(.title3)
            Text("HP recomputes from the frozen spawn averages.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func autokillControl(_ record: MonsterRecord) -> some View {
        Section {
            Button(role: .destructive) { confirmingAutokill = true } label: {
                Label("Autokill (end this monster now)", systemImage: "bolt.fill").font(.title3.bold())
            }
            .confirmationDialog("End this monster now and spawn the next?",
                                isPresented: $confirmingAutokill, titleVisibility: .visible) {
                Button("Autokill", role: .destructive) { store.autokill(recordID: record.id) }
            }
        }
    }

    // MARK: - No live monster → spawn

    private var spawnControls: some View {
        Section("No active monster") {
            Text("This team has no monster in play. Spawn one to begin.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Monster", selection: $spawnTemplateID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(store.state.monsterCatalog.filter { $0.kind == .regular }) {
                    Text($0.name).tag(UUID?.some($0.id))
                }
            }
            Button {
                if let team = teamID, let template = spawnTemplateID {
                    store.spawnInitialMonster(teamID: team, templateID: template)
                    spawnTemplateID = nil
                }
            } label: {
                Label("Start Battle", systemImage: "play.fill").font(.title3.bold())
            }
            .disabled(spawnTemplateID == nil)
        }
    }

    private func templateName(_ id: UUID) -> String {
        store.state.monsterCatalog.first { $0.id == id }?.name ?? "Unknown"
    }
}
