import Foundation

struct BackupRecord: Codable {
    let version: Int
    let client: ClientKind
    let createdAt: Date
    var originals: [FileSnapshot]
    var appliedHashes: [String: String]
}

final class BackupStore {
    let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let override = ProcessInfo.processInfo.environment["RELAY_SETUP_SUPPORT_DIR"],
                  !override.isEmpty {
            self.directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("RelaySetup", isDirectory: true)
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func record(for client: ClientKind) throws -> BackupRecord? {
        let url = recordURL(for: client)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(BackupRecord.self, from: Data(contentsOf: url))
        } catch {
            throw RelaySetupError.file("备份记录损坏：\(error.localizedDescription)")
        }
    }

    func ensureBaseline(for client: ClientKind, paths: [URL]) throws {
        if var existing = try record(for: client) {
            let recordedPaths = Set(existing.originals.map(\.path))
            let additions = try paths
                .filter { !recordedPaths.contains($0.path) }
                .map(PrivateFileSystem.snapshot)
            if !additions.isEmpty {
                existing.originals.append(contentsOf: additions)
                try save(existing)
            }
            return
        }

        let originals = try paths.map(PrivateFileSystem.snapshot)
        let record = BackupRecord(
            version: 1,
            client: client,
            createdAt: Date(),
            originals: originals,
            appliedHashes: [:]
        )
        try save(record)
    }

    func markApplied(for client: ClientKind, paths: [URL]) throws {
        guard var record = try record(for: client) else { throw RelaySetupError.noBackup }
        record.appliedHashes = try Dictionary(uniqueKeysWithValues: paths.map {
            ($0.path, try PrivateFileSystem.hash(of: $0))
        })
        try save(record)
    }

    func status(for client: ClientKind) throws -> ConfigurationStatus {
        guard let record = try record(for: client) else { return .notConfigured }
        for (path, expectedHash) in record.appliedHashes {
            if try PrivateFileSystem.hash(of: URL(fileURLWithPath: path)) != expectedHash {
                return .changed
            }
        }
        return record.appliedHashes.isEmpty ? .notConfigured : .configured
    }

    func restore(client: ClientKind, force: Bool) throws {
        guard let record = try record(for: client) else { throw RelaySetupError.noBackup }
        if !force, try status(for: client) == .changed {
            throw RelaySetupError.restoreConflict
        }
        for snapshot in record.originals.reversed() {
            try PrivateFileSystem.restore(snapshot)
        }
        do {
            try FileManager.default.removeItem(at: recordURL(for: client))
        } catch {
            throw RelaySetupError.file(error.localizedDescription)
        }
    }

    private func save(_ record: BackupRecord) throws {
        do {
            let data = try encoder.encode(record)
            try PrivateFileSystem.write(data, to: recordURL(for: record.client))
        } catch let error as RelaySetupError {
            throw error
        } catch {
            throw RelaySetupError.file(error.localizedDescription)
        }
    }

    private func recordURL(for client: ClientKind) -> URL {
        directory.appendingPathComponent("\(client.rawValue)-backup.json")
    }
}
