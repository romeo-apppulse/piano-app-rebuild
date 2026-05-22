//
//  BackupSection.swift
//  PianoAppv2
//
//  Settings UI for: recovered-team warning, manual export, manual restore.
//

import SwiftUI
import UniformTypeIdentifiers

struct BackupSection: View {
    @ObservedObject var teamDeck: TeamDeck

    @State private var showExporter = false
    @State private var showImporter = false
    @State private var exportDocument: BackupDocument?
    @State private var statusMessage: String?

    var body: some View {
        Section(header: Text("Backup & Restore")) {

            // Warning banner: any teams whose HP came back missing on load.
            if !teamDeck.recoveredTeamNames.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("⚠️ These teams have missing HP and need to be re-saved:")
                        .font(Font.custom("PermanentMarker-Regular", size: 20))
                        .foregroundColor(.orange)
                    ForEach(teamDeck.recoveredTeamNames, id: \.self) { name in
                        Text("• \(name)")
                            .font(Font.custom("PermanentMarker-Regular", size: 18))
                    }
                    Text("Open each team above and re-enter Min HP and Max HP, then restart the app to clear this warning.")
                        .font(.footnote)
                }
                .padding(.vertical, 6)
            }

            Button {
                do {
                    let data = try BackupManager.makeExportData()
                    exportDocument = BackupDocument(data: data)
                    showExporter = true
                } catch {
                    statusMessage = "Could not prepare backup: \(error.localizedDescription)"
                }
            } label: {
                bigButtonLabel(text: "Export Backup",
                               symbol: "square.and.arrow.up",
                               background: Color(red: 1, green: 0.557, blue: 0))
            }

            Button {
                showImporter = true
            } label: {
                bigButtonLabel(text: "Restore from Backup",
                               symbol: "square.and.arrow.down",
                               background: Color.white)
            }

            if let msg = statusMessage {
                Text(msg)
                    .font(.footnote)
                    .padding(.top, 4)
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "PianoAppBackup-\(BackupDocument.timestampForFilename()).json"
        ) { result in
            switch result {
            case .success:
                statusMessage = "Backup saved."
            case .failure(let error):
                statusMessage = "Export cancelled or failed: \(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    try BackupManager.restore(from: url)
                    statusMessage = "Restore complete. Quit and reopen the app to load the restored data."
                } catch {
                    statusMessage = "Restore failed: \(error.localizedDescription)"
                }
            case .failure(let error):
                statusMessage = "Could not open file: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func bigButtonLabel(text: String, symbol: String, background: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(Font.custom("PermanentMarker-Regular", size: 24))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .background(background)
            .clipShape(Capsule())
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static func timestampForFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
