//
//  BackupView.swift
//  PianoApp
//
//  Manual export / restore of the entire app state as one JSON document. Mirrors the
//  legacy app's backup affordance, but over the single atomic appState document.
//

import SwiftUI
import UniformTypeIdentifiers
import PianoCore

struct BackupView: View {
    @EnvironmentObject private var store: GameStore

    @State private var showExporter = false
    @State private var showImporter = false
    @State private var document: AppBackupDocument?
    @State private var status: String?

    var body: some View {
        List {
            Section {
                Text("Export writes a full copy of everything (students, teams, monsters, combat log). Restore replaces the current state.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Button {
                    if let data = store.exportData() {
                        document = AppBackupDocument(data: data)
                        showExporter = true
                    } else {
                        status = "Nothing to export yet."
                    }
                } label: {
                    Label("Export Backup", systemImage: "square.and.arrow.up").font(.title3.bold())
                }

                Button {
                    showImporter = true
                } label: {
                    Label("Restore from Backup", systemImage: "square.and.arrow.down").font(.title3.bold())
                }
            }

            if let status {
                Section { Text(status).font(.footnote) }
            }
        }
        .navigationTitle("Backup & Restore")
        .fileExporter(isPresented: $showExporter, document: document, contentType: .json,
                      defaultFilename: "PianoAppBackup-\(Self.timestamp())") { result in
            switch result {
            case .success: status = "Backup saved."
            case .failure(let error): status = "Export cancelled or failed: \(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), store.importBackup(data) {
                    status = "Restore complete."
                } else {
                    status = "Restore failed: could not read or decode that file."
                }
            case .failure(let error):
                status = "Could not open file: \(error.localizedDescription)"
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}

struct AppBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
