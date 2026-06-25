//
//  Persistence.swift — single-file atomic persistence for the whole AppState.
//
//  The old app archived four separate JSON files and could be interrupted mid-write
//  (it saved battleDeck and studentDeck in two steps inside attack()), leaving torn
//  cross-file state — the root cause of the "won't load, must re-download" symptom.
//
//  Here the ENTIRE state is one document written with `.atomic` (temp file + rename),
//  so a crash or app-suspend can never produce a half-written or internally
//  inconsistent file: a save either fully lands or doesn't happen at all. Rolling
//  backups (.bak1/.bak2) are rotated before each write as a second safety net.
//
//  Pure Foundation (no SwiftUI/Combine) so it stays cross-platform testable. The
//  directory is injected, so tests run against a temp dir and the app passes its
//  Documents directory.
//

import Foundation

public enum PersistenceError: Error, Equatable {
    case fileNotFound
    case decodeFailed(String)
    case encodeFailed(String)
    case writeFailed(String)
}

public protocol PersistenceController {
    func exists() -> Bool
    func load() throws -> AppState
    func save(_ state: AppState) throws
}

public struct JSONFilePersistence: PersistenceController {
    public let directory: URL
    public let fileName: String
    /// Number of rolling backups to keep (.bak1 ... .bakN). 0 disables backups.
    public let backupDepth: Int

    public init(directory: URL, fileName: String = "appState.json", backupDepth: Int = 2) {
        self.directory = directory
        self.fileName = fileName
        self.backupDepth = backupDepth
    }

    public var fileURL: URL { directory.appendingPathComponent(fileName) }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // human-readable + stable diffs
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func load() throws -> AppState {
        guard let data = try? Data(contentsOf: fileURL) else { throw PersistenceError.fileNotFound }
        do {
            return try Self.makeDecoder().decode(AppState.self, from: data)
        } catch {
            throw PersistenceError.decodeFailed(String(describing: error))
        }
    }

    public func save(_ state: AppState) throws {
        let data: Data
        do {
            data = try Self.makeEncoder().encode(state)
        } catch {
            throw PersistenceError.encodeFailed(String(describing: error))
        }

        ensureDirectoryExists()
        rotateBackups()

        do {
            try data.write(to: fileURL, options: .atomic) // temp + rename: all-or-nothing
        } catch {
            throw PersistenceError.writeFailed(String(describing: error))
        }
    }

    // MARK: - Internals

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func backupURL(_ index: Int) -> URL {
        directory.appendingPathComponent("\(fileName).bak\(index)")
    }

    /// Rolls .bak(n-1) → .bak(n) (oldest dropped), then current file → .bak1, before a
    /// write. Best-effort and silent: a rotation failure never blocks the real save.
    private func rotateBackups() {
        guard backupDepth > 0 else { return }
        let fm = FileManager.default

        // Drop the oldest, then shift each backup down one slot.
        try? fm.removeItem(at: backupURL(backupDepth))
        var index = backupDepth - 1
        while index >= 1 {
            let from = backupURL(index)
            let to = backupURL(index + 1)
            if fm.fileExists(atPath: from.path) {
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
            index -= 1
        }

        // Copy the current live file into .bak1.
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: backupURL(1))
            try? fm.copyItem(at: fileURL, to: backupURL(1))
        }
    }
}
