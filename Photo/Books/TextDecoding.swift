import Foundation

/// 中文 TXT 小说的编码嗅探。
///
/// 网上流传的中文 TXT 绝大多数是 GB18030（GBK/GB2312 的超集），少部分 UTF-8，
/// 极少数 UTF-16 或 Big5。不做嗅探直接按 UTF-8 读，十本里有八本是乱码。
enum TextDecoding {

    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return "" }

        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return String(data: data.dropFirst(4), encoding: .utf32LittleEndian)
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: data.dropFirst(4), encoding: .utf32BigEndian)
        }
        // 1. BOM 最可靠，优先看
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }

        // 2. 严格 UTF-8：非法字节序列会返回 nil，所以能解出来基本就是 UTF-8
        if let utf8 = String(data: data, encoding: .utf8), !utf8.contains("\0") {
            return utf8
        }

        // 3. GB18030。它几乎能吞下任意字节序列，所以必须排在 UTF-8 之后
        if let gb = string(from: data, cfEncoding: CFStringEncodings.GB_18030_2000),
           looksLikeChinese(gb) {
            return gb
        }

        // 4. 繁体的可能是 Big5
        if let big5 = string(from: data, cfEncoding: CFStringEncodings.big5),
           looksLikeChinese(big5) {
            return big5
        }

        return nil

    }

    private static func string(from data: Data, cfEncoding: CFStringEncodings) -> String? {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding.rawValue))
        guard raw != kCFStringEncodingInvalidId else { return nil }
        return String(data: data, encoding: String.Encoding(rawValue: raw))
    }

    /// 抽样看 CJK 字符占比，用来判断某个编码解出来的是不是「像中文」
    private static func looksLikeChinese(_ text: String) -> Bool {
        let sample = text.prefix(2000)
        guard !sample.isEmpty else { return false }

        var cjk = 0
        var replacement = 0
        for scalar in sample.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3000...0x303F, 0xFF00...0xFFEF:
                cjk += 1
            case 0xFFFD:              // 替换字符，说明解码出问题了
                replacement += 1
            default:
                break
            }
        }
        if replacement > sample.count / 50 { return false }
        return Double(cjk) / Double(sample.count) > 0.2
    }
}
