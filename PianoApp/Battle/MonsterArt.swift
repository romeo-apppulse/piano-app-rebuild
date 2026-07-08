//
//  MonsterArt.swift
//  PianoApp
//
//  Renders a monster template's art with a bounded (memory-flat) decode, falling back to a
//  bold placeholder when the art is missing — migrated templates reference filenames whose
//  bytes may not exist until the teacher assigns art in the catalog.
//

import SwiftUI
import PianoCore

struct MonsterArt: View {
    @EnvironmentObject private var store: GameStore
    let template: MonsterTemplate?

    var body: some View {
        if let image = loadedImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 24))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.thinMaterial)
                VStack(spacing: 16) {
                    Image(systemName: template?.kind == .miniboss ? "crown.fill" : "pawprint.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(template?.kind == .miniboss ? .orange : .secondary)
                    if let name = template?.name {
                        Text(name).font(.largeTitle.bold()).multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
        }
    }

    /// Bounded thumbnail decode from the STORE's directory (not the static `documentsDirectory`,
    /// which would miss art under a seeded/UITest fixture dir). 1600 px caps display memory: the
    /// art renders at ~360 pt (~720 px @2×), so this is already >2× what the screen needs.
    private var loadedImage: UIImage? {
        guard let name = template?.imageFileName, !name.isEmpty else { return nil }
        return MonsterImageStore.thumbnail(filename: name, in: store.imageDirectory, maxPixel: 1600)
    }
}
