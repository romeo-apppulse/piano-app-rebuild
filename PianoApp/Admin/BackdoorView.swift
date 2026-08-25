//
//  BackdoorView.swift
//  PianoApp
//
//  Teacher admin controls on a LIVE monster. All mutations are TYPED, undoable engine
//  actions: adjust HP (±, no log entry), change kill-target (auto recalculates HP),
//  autokill (ends the monster, spawns the successor), and fix-the-last-entry
//  (edit/delete the most recent attack — the only entry the policy allows touching).
//
//  Reaches BOTH kinds of live monster:
//    • an ACTIVE MINIBOSS gets its own section (it has no team, so the team picker
//      can't reach it) — including "end early", which is how a miniboss is cut short;
//    • the selected team's regular monster, exactly as before.
//

import SwiftUI
import PianoCore

struct BackdoorView: View {
    @EnvironmentObject private var store: GameStore

    @State private var teamID: UUID?
    @State private var spawnTemplateID: UUID?
    @State private var confirmingAutokill = false
    @State private var confirmingEndMiniboss = false

    private var selectedTeam: Team? { store.state.teams.first { $0.id == teamID } }
    private var live: MonsterRecord? { teamID.flatMap { store.liveMonster(forTeam: $0) } }
    private var miniboss: MonsterRecord? { store.state.aliveMiniboss }

    var body: some View {
        List {
            if let miniboss {
                minibossSection(miniboss)
            }

            Section("Team") {
                Picker("Team", selection: $teamID) {
                    Text("Choose a team").tag(UUID?.none)
                    ForEach(store.state.teams) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }

            if let record = live {
                monsterStats(record, title: "Current monster")
                hpFormula(record)
                if miniboss != nil {
                    Section {
                        Text("This team's battle is paused while the miniboss is active. HP and kill-target edits still apply; it can't be attacked or autokilled until the miniboss ends.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                hpControls(record)
                killTargetControls(record)
                if miniboss == nil {
                    autokillControl(record)
                    lastEntrySection(scope: teamID, context: "this team")
                }
            } else if selectedTeam != nil, miniboss == nil {
                spawnControls
            }
        }
        .navigationTitle("Backdoor Controls")
    }

    // MARK: - Active miniboss (no team → needs its own section)

    @ViewBuilder
    private func minibossSection(_ record: MonsterRecord) -> some View {
        Section {
            Label("Miniboss active — all teams are fighting it", systemImage: "crown.fill")
                .font(.title3.bold()).foregroundStyle(.orange)
        }
        monsterStats(record, title: "Miniboss")
        hpFormula(record)
        hpControls(record)
        killTargetControls(record)
        Section {
            Button(role: .destructive) { confirmingEndMiniboss = true } label: {
                Label("End miniboss early", systemImage: "bolt.fill").font(.title3.bold())
            }
            .confirmationDialog("End the miniboss now? Teams resume their paused battles.",
                                isPresented: $confirmingEndMiniboss, titleVisibility: .visible) {
                Button("End miniboss", role: .destructive) { store.autokill(recordID: record.id) }
            }
            Text("Locks in the miniboss leaderboard and resumes every team where it paused.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        // During a miniboss, the most recent attack is on the miniboss → global scope.
        lastEntrySection(scope: nil, context: "the miniboss")
    }

    // MARK: - Shared monster controls

    private func monsterStats(_ record: MonsterRecord, title: String) -> some View {
        Section(title) {
            LabeledContent("Name", value: templateName(record.templateID))
            LabeledContent("Effective HP", value: "\(store.state.effectiveHP(of: record))")
            LabeledContent("Damage dealt", value: "\(store.state.damageDealt(toMonster: record.id))")
            LabeledContent("Remaining HP") {
                Text("\(store.state.remainingHP(of: record))").font(.title3.bold().monospacedDigit())
            }
        }
    }

    /// Shows exactly how this monster's HP was derived (client change request), and —
    /// because the same numbers explain it — why small backdoor ± taps can look like they
    /// do nothing when the HP is sitting on the minimum floor (the reported bug).
    @ViewBuilder
    private func hpFormula(_ record: MonsterRecord) -> some View {
        let minHP = store.state.settings.minimumMonsterHP
        let offset = record.backdoorHPDelta
        let averages = record.spawnAverages.map { $0.average }
        let base = MonsterMath.baseHP(dailyAverages: averages, killTargetWeeks: record.killTargetWeeks)
        let raw = (record.legacyFixedHP ?? base) + offset

        Section("How this HP was calculated") {
            if let fixed = record.legacyFixedHP {
                Text("Migrated monster — HP pinned at \(fixed)\(offsetText(offset)) = \(raw).")
                    .font(.footnote.monospaced())
            } else {
                Text("⌈avg \(String(format: "%.1f", averages.reduce(0, +))) × \(record.killTargetWeeks) wk⌉ = \(base)\(offsetText(offset)) = \(raw).")
                    .font(.footnote.monospaced())
            }
            if raw < minHP {
                Text("That's below the \(minHP) HP minimum, so the bar is floored to \(minHP). Backdoor ± changes below the floor won't move the bar until they lift it back above \(minHP) — that's why a small tap can look like it did nothing.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Effective HP: \(store.state.effectiveHP(of: record)) (minimum is \(minHP)).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func offsetText(_ offset: Int) -> String {
        if offset == 0 { return "" }
        return offset > 0 ? " + offset \(offset)" : " − offset \(abs(offset))"
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

    // MARK: - Fix the last entry (most-recent-only policy)

    @ViewBuilder
    private func lastEntrySection(scope: UUID?, context: String) -> some View {
        if let attack = store.mostRecentAttack(teamScope: scope),
           let first = attack.entries.first {
            LastEntryEditor(scope: scope,
                            context: context,
                            studentName: store.state.displayName(first.studentID),
                            currentAmount: attack.entries.reduce(0) { $0 + $1.amount })
        } else {
            Section("Fix the last entry") {
                Text("Nothing editable right now — the most recent action for \(context) isn't a logged attack. Older entries are locked.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - No live monster → spawn

    @ViewBuilder
    private var spawnControls: some View {
        if !store.state.lineup.isEmpty {
            // A lineup exists → start from it so the slot id and pointer advance and the
            // lineup (and any miniboss) stays in sync with the battle. Normally teams are
            // auto-started when the lineup is saved; this is the per-team catch-up.
            Section("No active monster") {
                Text("This team has no monster in play. Start it on the next monster in the lineup.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    if let team = teamID { store.spawnFromLineup(teamID: team) }
                } label: {
                    Label("Start from lineup", systemImage: "play.fill").font(.title3.bold())
                }
            }
        } else {
            // No lineup configured → fall back to hand-picking a monster.
            Section("No active monster") {
                Text("This team has no monster in play. Spawn one to begin (or set up a Lineup so teams start automatically).")
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
    }

    private func templateName(_ id: UUID) -> String {
        store.state.monsterCatalog.first { $0.id == id }?.name ?? "Unknown"
    }
}

/// Edit or delete the most recent attack in scope. Edit = the engine's undo+re-apply
/// (kill/carryover consequences recompute exactly); delete = the same operation as
/// Undo. Own struct so its @State resets cleanly via .id() when the target changes.
private struct LastEntryEditor: View {
    @EnvironmentObject private var store: GameStore

    let scope: UUID?
    let context: String
    let studentName: String
    let currentAmount: Int

    @State private var newAmount = ""
    @State private var confirmingDelete = false

    var body: some View {
        Section("Fix the last entry") {
            LabeledContent("Most recent", value: "\(studentName) — \(currentAmount) dmg")

            HStack {
                TextField("New amount", text: $newAmount)
                    .keyboardType(.numberPad)
                    .font(.title3.monospacedDigit())
                Button("Save") {
                    if let amount = Int(newAmount), amount > 0 {
                        store.editMostRecentAttack(teamScope: scope, newAmount: amount)
                        newAmount = ""
                    }
                }
                .font(.title3.bold())
                .buttonStyle(.borderedProminent)
                .disabled((Int(newAmount) ?? 0) <= 0)
            }

            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete this entry", systemImage: "trash")
            }
            .confirmationDialog("Delete \(studentName)'s \(currentAmount)-damage entry? Same as Undo — a kill it caused is reversed too.",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { store.deleteMostRecentEntry(teamScope: scope) }
            }

            Text("Only the most recent entry can be changed; earlier entries are locked. Editing recomputes any kill or carryover it caused.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .id("\(studentName)-\(currentAmount)")   // reset the field when the target entry changes
    }
}
