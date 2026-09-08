import Foundation

final class SavedRelayStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil) {
        let supportDirectory: URL
        if let directory {
            supportDirectory = directory
        } else if let override = ProcessInfo.processInfo.environment["RELAY_SETUP_SUPPORT_DIR"],
                  !override.isEmpty {
            supportDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            supportDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("RelaySetup", isDirectory: true)
        }
        fileURL = supportDirectory.appendingPathComponent("saved-relays.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> [SavedRelayProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try decoder.decode([SavedRelayProfile].self, from: Data(contentsOf: fileURL))
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            throw RelaySetupError.file("保存的中转站无法读取：\(error.localizedDescription)")
        }
    }

    func save(_ profiles: [SavedRelayProfile]) throws {
        do {
            try PrivateFileSystem.write(try encoder.encode(profiles), to: fileURL)
        } catch let error as RelaySetupError {
            throw error
        } catch {
            throw RelaySetupError.file("保存中转站失败：\(error.localizedDescription)")
        }
    }
}
