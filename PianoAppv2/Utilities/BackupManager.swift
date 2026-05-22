//
//  BackupManager.swift
//  PianoAppv2
//
//  Export/restore of all four live JSON files as a single backup payload.
//  Pure Foundation, no UI — the SwiftUI BackupSection drives this.
//

import Foundation

enum BackupManager {

    private static let exportVersion = 1

    /// Single combined backup. Each entry is the raw bytes of one of the live
    /// JSON files; Codable encodes Data as base64 in the wrapper JSON. Storing
    /// the raw bytes (rather than re-decoded objects) means a backup still works
    /// even if one of the source files is malformed JSON.
    struct ExportPayload: Codable {
        let version: Int
        let exportedAt: Date
        let files: [String: Data]
    }

    enum BackupError: LocalizedError {
        case unreadable
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "The backup file could not be read."
            case .unsupportedVersion(let v):
                return "Backup version \(v) is newer than this app supports."
            }
        }
    }

    /// Bundles whichever of the live JSON files currently exist into a single Data blob.
    static func makeExportData() throws -> Data {
        let docs = DataStore.documentsURL()
        var files: [String: Data] = [:]
        for name in DataStore.dataFileNames {
            let url = docs.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) {
                files[name] = data
            }
        }
        let payload = ExportPayload(version: exportVersion, exportedAt: Date(), files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    /// Restores from a security-scoped URL (from .fileImporter).
    /// Rotates each target file's backups before overwriting, so a bad restore
    /// can still be rolled back via .bak1/.bak2.
    static func restore(from sourceURL: URL) throws {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: sourceURL) else {
            throw BackupError.unreadable
        }
        try restore(fromData: data)
    }

    /// Restores from raw backup Data (used directly by tests and by restore(from:)).
    static func restore(fromData data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ExportPayload.self, from: data)

        guard payload.version <= exportVersion else {
            throw BackupError.unsupportedVersion(payload.version)
        }

        let docs = DataStore.documentsURL()
        for (name, fileData) in payload.files {
            // Only restore files we actually recognize — ignore anything else in the payload.
            guard DataStore.dataFileNames.contains(name) else { continue }
            let url = docs.appendingPathComponent(name)
            DataStore.rotateBackups(for: url)
            try fileData.write(to: url, options: .atomic)
        }
    }
}
