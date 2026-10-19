import Foundation
import CoreFoundation

/// 先按明确的 Unicode 标记解码；无标记的旧编码交给 Foundation 识别。
/// 只允许支持的编码和无损转换，不以中文占比判定文件是否有效。
enum TextDecoding {
    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return "" }

        // UTF-32 的 BOM 包含 UTF-16 前缀，必须先检查。
        let signatures: [([UInt8], String.Encoding)] = [
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian)
        ]
        for (bom, encoding) in signatures where data.starts(with: bom) {
            let payload = data.dropFirst(bom.count)
            guard let text = String(data: payload, encoding: encoding), isText(text),
                  text.data(using: encoding, allowLossyConversion: false) == payload else { return nil }
            return text
        }
        if let text = String(data: data, encoding: .utf8), isText(text) { return text }

        if data.contains(0) {
            return decodeUnmarkedUnicode(data)
        }
        let encodings = [CFStringEncodings.GB_18030_2000, .big5].map {
            CFStringConvertEncodingToNSStringEncoding(CFStringEncoding($0.rawValue))
        }
        var detected: NSString?
        var lossy: ObjCBool = false
        let encoding = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: encodings,
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: false
        ], convertedString: &detected, usedLossyConversion: &lossy)
        guard encodings.contains(encoding), !lossy.boolValue, let detected,
              isText(detected as String) else { return nil }
        return detected as String
    }

    private static func decodeUnmarkedUnicode(_ data: Data) -> String? {
        // 无 BOM 时以完整码元、无损往返和 ASCII/换行的字节位置判断字节序。
        // 两种字节序同样可能时明确拒绝，不任意选择会产生乱码的一种。
        let encodings: [String.Encoding] = [.utf32LittleEndian, .utf32BigEndian,
                                            .utf16LittleEndian, .utf16BigEndian]
        var result: String?
        var strongestEvidence = -1
        for encoding in encodings {
            guard let text = String(data: data, encoding: encoding), isText(text),
                  text.data(using: encoding, allowLossyConversion: false) == data else { continue }
            let evidence = text.unicodeScalars.reduce(0) { count, scalar in
                count + (scalar.value < 0x7F ? 1 : 0)
            }
            if evidence > strongestEvidence {
                strongestEvidence = evidence
                result = text
            } else if evidence == strongestEvidence {
                result = nil
            }
        }
        return result
    }

    private static func isText(_ text: String) -> Bool {
        // 保留制表、换行、换页和回车；拒绝二进制控制字符。
        !text.unicodeScalars.contains {
            ($0.value < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D].contains($0.value))
                || $0.value == 0x7F
        }
    }
}
