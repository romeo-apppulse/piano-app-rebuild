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
    @State private var loaded = false
    @State private var addTemplateID: UUID?

    private var dirty: Bool { slots != store.state.lineup }

    var body: some View {
        List {
            Section {
                Text("Teams face these monsters in order. A miniboss slot pauses all teams when the first team reaches it.")
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
                Button("Save") { store.setLineup(slots) }
                    .bold()
                    .disabled(!dirty)
            }
        }
        .onAppear { if !loaded { slots = store.state.lineup; loaded = true } }
    }

    private func template(_ slot: LineupSlot) -> MonsterTemplate? {
        store.state.monsterCatalog.first { $0.id == slot.templateID }
    }
    private func name(_ slot: LineupSlot) -> String { template(slot)?.name ?? "Unknown monster" }
    private func kind(_ slot: LineupSlot) -> MonsterKind { template(slot)?.kind ?? .regular }
}
