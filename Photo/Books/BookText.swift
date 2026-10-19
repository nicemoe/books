import Foundation

/// 阅读位置统一使用 UTF-16，与 NSString、CoreText 的范围单位一致。
enum BookText {
    static func read(_ url: URL, offset: Int, length: Int) throws -> String {
        guard offset >= 0, length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard UInt64(offset) <= size, UInt64(length) <= size - UInt64(offset) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: length), data.count == length,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }

    static func snippet(_ text: String, at offset: Int, length: Int = 40) -> String {
        let value = text as NSString
        guard offset >= 0, offset < value.length else { return "" }
        let range = value.rangeOfComposedCharacterSequences(
            for: NSRange(location: offset, length: min(length, value.length - offset)))
        return value.substring(with: range)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
