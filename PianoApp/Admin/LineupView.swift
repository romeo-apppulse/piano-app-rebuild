//
//  LineupView.swift
//  PianoApp
//
//  Edits the shared, ordered monster lineup (add / reorder / remove slots, including
//  miniboss placement). Edited locally, then committed through the TYPED engine method
//  GameEngine.setLineup (undoable, validated) — never through `apply`.
//

import SwiftUI
import PianoCore

struct LineupView: View {
    @EnvironmentObject private var store: GameStore

    @State private var slots: [LineupSlot] = []
    /// The last-known store lineup this editor was in sync with. `dirty` compares against
    /// this (not the live store) so an external change (e.g. an undo) can be adopted
    /// without falsely reading as a pending edit.
    @State private var baseline: [LineupSlot] = []
    @State private var loaded = false
    @State private var addTemplateID: UUID?

    private var dirty: Bool { slots != baseline }

    var body: some View {
        List {
            Section {
                Text("Teams face these monsters in order. A miniboss slot pauses all teams when the first team reaches it. Drag the ≡ handle (via Edit) to reorder. Saving starts every team that isn't already fighting at the beginning of the lineup.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Add slot") {
                Picker("Monster", selection: $addTemplateID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(store.state.monsterCatalog) { template in
                        Text("\(template.name)\(template.kind == .miniboss ? " (miniboss)" : "")")
                            .tag(UUID?.some(template.id))
                    }
                }
                Button {
                    if let id = addTemplateID { slots.append(LineupSlot(templateID: id)); addTemplateID = nil }
                } label: {
                    Label("Append to Lineup", systemImage: "plus.circle.fill").font(.title3.bold())
                }
                .disabled(addTemplateID == nil)
            }

            Section("Lineup (\(slots.count))") {
                if slots.isEmpty {
                    Text("Empty lineup falls back to cycling the catalog in order.").foregroundStyle(.secondary)
                }
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    HStack {
                        Text("\(index + 1)").font(.headline).foregroundStyle(.secondary).frame(width: 28)
                        Image(systemName: kind(slot) == .miniboss ? "crown.fill" : "pawprint.fill")
                            .foregroundStyle(kind(slot) == .miniboss ? .orange : .secondary)
                        Text(name(slot)).font(.title3)
                        Spacer()
                    }
                }
                .onMove { slots.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { slots.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("Lineup")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    store.setLineup(slots)
                    store.startIdleTeamsFromLineup()   // idle teams begin at the top of the new lineup
                    baseline = slots
                }
                .bold()
                .disabled(!dirty)
            }
        }
        .onAppear { if !loaded { slots = store.state.lineup; baseline = slots; loaded = true } }
        .onChange(of: store.state.lineup) { newValue in
            // Adopt an external change only when the user has no pending edits.
            if slots == baseline { slots = newValue; baseline = newValue }
        }
    }

    private func template(_ slot: LineupSlot) -> MonsterTemplate? {
        store.state.monsterCatalog.first { $0.id == slot.templateID }
    }
    private func name(_ slot: LineupSlot) -> String { template(slot)?.name ?? "Unknown monster" }
    private func kind(_ slot: LineupSlot) -> MonsterKind { template(slot)?.kind ?? .regular }
}
