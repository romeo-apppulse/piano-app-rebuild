//
//  CatalogView.swift
//  PianoApp
//
//  The monster "deck": reusable templates. Regular vs miniboss. Art is assigned with the
//  Files image picker — the same picker is reused for the Add form and for a per-row
//  assign/replace affordance. Existing (incl. migrated) templates can get art WITHOUT
//  delete-and-re-add, which would orphan lineup slots and historical records that reference
//  the template id.
//

import SwiftUI
import PianoCore

struct CatalogView: View {
    @EnvironmentObject private var store: GameStore

    @State private var newName = ""
    @State private var newArtist = ""
    @State private var newKind: MonsterKind = .regular
    /// Art chosen for the not-yet-added monster. Bytes are already on disk once this is set
    /// (the picker writes immediately). If the teacher abandons the Add form, that file is a
    /// harmless orphan — the same class as the deferred replace-time orphan cleanup, not a
    /// leak to "fix" by deleting eagerly (a .bak restore could still reference it).
    @State private var pickedNewImageName: String?

    /// Which template the picker is assigning to (`nil`-identity `.newMonster` = the Add form).
    @State private var pickTarget: PickTarget?
    @State private var errorMessage: String?

    private enum PickTarget: Identifiable {
        case newMonster
        case existing(UUID)
        var id: String {
            switch self {
            case .newMonster: return "new"
            case .existing(let id): return id.uuidString
            }
        }
    }

    var body: some View {
        List {
            Section("Add monster") {
                TextField("Name", text: $newName).font(.title3)
                TextField("Artist (optional)", text: $newArtist)

                Button {
                    pickTarget = .newMonster
                } label: {
                    HStack {
                        Label(pickedNewImageName == nil ? "Choose image…" : "Change image",
                              systemImage: "photo.on.rectangle")
                        Spacer()
                        thumbnail(for: pickedNewImageName, kind: newKind)
                    }
                }

                Picker("Kind", selection: $newKind) {
                    Text("Regular").tag(MonsterKind.regular)
                    Text("Miniboss").tag(MonsterKind.miniboss)
                }
                .pickerStyle(.segmented)

                Button {
                    store.addTemplate(name: newName,
                                      kind: newKind,
                                      artist: newArtist.isEmpty ? nil : newArtist,
                                      imageFileName: pickedNewImageName)
                    newName = ""; newArtist = ""; pickedNewImageName = nil; newKind = .regular
                } label: {
                    Label("Add to Catalog", systemImage: "plus.circle.fill").font(.title3.bold())
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section("Catalog (\(store.state.monsterCatalog.count))") {
                if store.state.monsterCatalog.isEmpty { Text("No monsters yet").foregroundStyle(.secondary) }
                ForEach(store.state.monsterCatalog) { template in
                    HStack(spacing: 12) {
                        thumbnail(for: template.imageFileName, kind: template.kind)
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
                        Button {
                            pickTarget = .existing(template.id)
                        } label: {
                            Image(systemName: template.imageFileName == nil ? "photo.badge.plus" : "photo")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)   // so the row's tap area doesn't swallow it
                        .accessibilityLabel(template.imageFileName == nil ? "Assign art" : "Replace art")
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
        .sheet(item: $pickTarget) { target in
            MonsterImagePicker(directory: store.imageDirectory) { result in
                handle(result, for: target)
            }
        }
        .alert("Image problem", isPresented: Binding(get: { errorMessage != nil },
                                                     set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// A 44×44 art preview, falling back to the kind's SF Symbol when there is no (loadable) art.
    @ViewBuilder
    private func thumbnail(for fileName: String?, kind: MonsterKind) -> some View {
        if let fileName,
           let image = MonsterImageStore.thumbnail(filename: fileName, in: store.imageDirectory, maxPixel: 88) {
            Image(uiImage: image)
                .resizable().scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: kind == .miniboss ? "crown.fill" : "pawprint.fill")
                .font(.title2)
                .frame(width: 44, height: 44)
                .foregroundStyle(kind == .miniboss ? .orange : .secondary)
        }
    }

    private func handle(_ result: Result<String, Error>, for target: PickTarget) {
        switch result {
        case .success(let name):
            switch target {
            case .newMonster: pickedNewImageName = name
            case .existing(let id): store.setTemplateImage(id, fileName: name)
            }
        case .failure(let error):
            errorMessage = (error as? MonsterImageStore.StoreError) == .notAnImage
                ? "That file isn't a readable image. Pick a photo or image file."
                : "Couldn't import that image. Please try another file."
        }
        pickTarget = nil
    }
}
