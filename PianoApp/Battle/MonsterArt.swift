//
//  MonsterArt.swift
//  PianoApp
//
//  Loads a monster template's image from Documents by filename. Falls back to a bold
//  placeholder when the art is missing (the real image picker lands in a later pass;
//  migrated templates reference filenames whose bytes may not exist yet).
//

import SwiftUI
import PianoCore

struct MonsterArt: View {
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

    private var loadedImage: UIImage? {
        guard let name = template?.imageFileName, !name.isEmpty else { return nil }
        let url = GameStore.documentsDirectory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
