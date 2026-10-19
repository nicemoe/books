import Foundation
import Compression

/// EPUB 所需的 ZIP 子集。损坏、加密或超过限制的条目明确报错。
enum MiniZip {
    static let maximumEntrySize = 32 * 1024 * 1024
    static let maximumExpandedSize = 256 * 1024 * 1024

    struct Entry {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let checksum: UInt32
    }

    enum ZipError: LocalizedError {
        case notZip
        case corrupted(String)
        var errorDescription: String? {
            switch self {
            case .notZip: return "不是有效的 EPUB（ZIP）文件"
            case .corrupted(let message): return "EPUB 无法读取：\(message)"
            }
        }
    }

    static func entries(in input: Data) throws -> [String: Entry] {
        let data = Data(input)
        guard let end = findEndOfCentralDirectory(data) else { throw ZipError.notZip }
        let count = Int(read16(data, end + 10))
        let centralSize = Int(read32(data, end + 12))
        let centralStart = Int(read32(data, end + 16))
        guard read16(data, end + 4) == 0, read16(data, end + 6) == 0,
              Int(read16(data, end + 8)) == count, count != 0xFFFF,
              centralStart <= end, centralSize == end - centralStart else {
            throw ZipError.corrupted("不支持分卷、ZIP64 或不完整中央目录")
        }
        var offset = centralStart
        var expanded = 0
        var result: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= end, read32(data, offset) == 0x02014B50 else {
                throw ZipError.corrupted("中央目录项越界")
            }
            let flags = read16(data, offset + 8)
            let method = read16(data, offset + 10)
            let compressed = Int(read32(data, offset + 20))
            let uncompressed = Int(read32(data, offset + 24))
            let nameLength = Int(read16(data, offset + 28))
            let extra = Int(read16(data, offset + 30))
            let comment = Int(read16(data, offset + 32))
            let local = Int(read32(data, offset + 42))
            let next = offset + 46 + nameLength + extra + comment
            expanded += uncompressed
            guard flags & 1 == 0, method == 0 || method == 8,
                  uncompressed <= maximumEntrySize, expanded <= maximumExpandedSize,
                  compressed <= data.count, local < centralStart, next <= end,
                  read16(data, offset + 34) == 0 else {
                throw ZipError.corrupted("加密、不支持的压缩方式、数据越界或解压大小超限")
            }
            guard let name = String(data: data[(offset + 46)..<(offset + 46 + nameLength)], encoding: .utf8),
                  !name.isEmpty else { throw ZipError.corrupted("无效文件名") }
            let key = normalize(name)
            guard !key.hasPrefix("../"), result[key] == nil else {
                throw ZipError.corrupted("重复或越界文件路径")
            }
            result[key] = Entry(path: name, compressionMethod: method, compressedSize: compressed,
                                uncompressedSize: uncompressed, localHeaderOffset: local,
                                checksum: read32(data, offset + 16))
            offset = next
        }
        guard offset == end else { throw ZipError.corrupted("中央目录长度不一致") }
        return result
    }

    static func extract(_ entry: Entry, from input: Data) throws -> Data {
        let data = Data(input)
        let head = entry.localHeaderOffset
        guard head >= 0, head + 30 <= data.count, read32(data, head) == 0x04034B50,
              read16(data, head + 6) & 1 == 0,
              read16(data, head + 8) == entry.compressionMethod,
              entry.uncompressedSize >= 0, entry.uncompressedSize <= maximumEntrySize,
              entry.compressedSize >= 0 else { throw ZipError.corrupted("本地文件头不一致") }
        let start = head + 30 + Int(read16(data, head + 26)) + Int(read16(data, head + 28))
        guard start <= data.count, entry.compressedSize <= data.count - start else {
            throw ZipError.corrupted("压缩数据越界")
        }
        let payload = Data(data[start..<(start + entry.compressedSize)])
        let output: Data
        switch entry.compressionMethod {
        case 0: output = payload
        case 8: output = try inflate(payload, expectedSize: entry.uncompressedSize)
        default: throw ZipError.corrupted("不支持的压缩方式")
        }
        guard output.count == entry.uncompressedSize, crc32(output) == entry.checksum else {
            throw ZipError.corrupted("解压长度或 CRC 校验失败：\(entry.path)")
        }
        return output
    }

    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        // 多留一个字节，用来发现实际内容大于声明长度的截断数据。
        let capacity = expectedSize + 1
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src -> Int in
                guard let destination = dst.bindMemory(to: UInt8.self).baseAddress,
                      let source = src.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_decode_buffer(destination, capacity, source, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.corrupted("解压长度不一致") }
        return Data(output.prefix(written))
    }

    private static func findEndOfCentralDirectory(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        for offset in stride(from: data.count - 22, through: max(0, data.count - 22 - 65535), by: -1) {
            if read32(data, offset) == 0x06054B50,
               offset + 22 + Int(read16(data, offset + 20)) == data.count { return offset }
        }
        return nil
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(read16(data, offset)) | (UInt32(read16(data, offset + 2)) << 16)
    }

    private static let crcTable: [UInt32] = (0..<256).map { byte in
        var value = UInt32(byte)
        for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xEDB88320 }
        return value
    }
    static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        for byte in data { value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
        return value ^ 0xFFFFFFFF
    }

    static func normalize(_ path: String) -> String {
        var components: [String] = []
        for part in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if part == "." { continue }
            if part == "..", let last = components.last, last != ".." { components.removeLast() }
            else { components.append(String(part)) }
        }
        return components.joined(separator: "/")
    }
}
