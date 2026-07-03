//
//  CatalogView.swift
//  PianoApp
//
//  The monster "deck": reusable templates. Regular vs miniboss. Images are referenced
//  by filename only for now (an image picker lands in a later pass).
//

import SwiftUI
import PianoCore

struct CatalogView: View {
    @EnvironmentObject private var store: GameStore

    @State private var newName = ""
    @State private var newArtist = ""
    @State private var newKind: MonsterKind = .regular
    @State private var newImage = ""

    var body: some View {
        List {
            Section("Add monster") {
                TextField("Name", text: $newName).font(.title3)
                TextField("Artist (optional)", text: $newArtist)
                TextField("Image filename (optional)", text: $newImage)
                    .autocorrectionDisabled()
                Picker("Kind", selection: $newKind) {
                    Text("Regular").tag(MonsterKind.regular)
                    Text("Miniboss").tag(MonsterKind.miniboss)
                }
                .pickerStyle(.segmented)
                Button {
                    store.addTemplate(name: newName,
                                      kind: newKind,
                                      artist: newArtist.isEmpty ? nil : newArtist,
                                      imageFileName: newImage.isEmpty ? nil : newImage)
                    newName = ""; newArtist = ""; newImage = ""; newKind = .regular
                } label: {
                    Label("Add to Catalog", systemImage: "plus.circle.fill").font(.title3.bold())
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section("Catalog (\(store.state.monsterCatalog.count))") {
                if store.state.monsterCatalog.isEmpty { Text("No monsters yet").foregroundStyle(.secondary) }
                ForEach(store.state.monsterCatalog) { template in
                    HStack(spacing: 12) {
                        Image(systemName: template.kind == .miniboss ? "crown.fill" : "pawprint.fill")
                            .foregroundStyle(template.kind == .miniboss ? .orange : .secondary)
                        VStack(alignment: .leading) {
                            Text(template.name).font(.title3)
                            if let artist = template.artist, !artist.isEmpty {
                                Text(artist).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(template.kind == .miniboss ? "Miniboss" : "Regular")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.thinMaterial, in: Capsule())
                    }
                }
                .onDelete { indexSet in
                    // Resolve ids up front: removeTemplate mutates the array, so indices
                    // captured against the old array would point at the wrong/absent row
                    // on a multi-row delete.
                    let ids = indexSet.map { store.state.monsterCatalog[$0].id }
                    for id in ids { store.removeTemplate(id) }
                }
            }
        }
        .navigationTitle("Monster Catalog")
    }
}
