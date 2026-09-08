import CryptoKit
import Darwin
import Foundation

struct FileSnapshot: Codable, Equatable {
    let path: String
    let existed: Bool
    let contents: Data?
    let permissions: UInt16?
}

enum PrivateFileSystem {
    static func snapshot(_ path: URL) throws -> FileSnapshot {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path.path) else {
            return FileSnapshot(path: path.path, existed: false, contents: nil, permissions: nil)
        }

        do {
            let attributes = try manager.attributesOfItem(atPath: path.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
            return FileSnapshot(
                path: path.path,
                existed: true,
                contents: try Data(contentsOf: path),
                permissions: permissions
            )
        } catch {
            throw RelaySetupError.file(error.localizedDescription)
        }
    }

    static func restore(_ snapshot: FileSnapshot) throws {
        let url = URL(fileURLWithPath: snapshot.path)
        if snapshot.existed {
            try removeCaseVariant(of: url)
            try write(snapshot.contents ?? Data(), to: url, permissions: snapshot.permissions ?? 0o600)
        } else if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw RelaySetupError.file(error.localizedDescription)
            }
        }
    }

    private static func removeCaseVariant(of url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let expectedName = url.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              let existingName = names.first(where: {
                  $0.caseInsensitiveCompare(expectedName) == .orderedSame && $0 != expectedName
              }) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(existingName))
        } catch {
            throw RelaySetupError.file(error.localizedDescription)
        }
    }

    static func write(_ data: Data, to url: URL, permissions: UInt16 = 0o600) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, mode_t(permissions)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch let error as RelaySetupError {
            throw error
        } catch {
            throw RelaySetupError.file(error.localizedDescription)
        }
    }

    static func hash(of url: URL) throws -> String {
        let snapshot = try snapshot(url)
        var payload = Data(snapshot.existed ? [1] : [0])
        if let contents = snapshot.contents {
            payload.append(contents)
        }
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}
