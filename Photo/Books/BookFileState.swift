import Foundation
import CryptoKit

/// Metadata is a quick change check; the digest decides whether chapter offsets changed.
enum BookFileState {
    struct Stamp: Codable, Equatable {
        let bytes: Int
        let modifiedAt: Double
    }

    static func stamp(_ url: URL) throws -> Stamp {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let bytes = values.fileSize, let date = values.contentModificationDate else {
            throw CocoaError(.fileReadUnknown)
        }
        return Stamp(bytes: bytes, modifiedAt: date.timeIntervalSince1970)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
