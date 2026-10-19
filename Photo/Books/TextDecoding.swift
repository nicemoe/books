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
            guard let text = String(data: data.dropFirst(bom.count), encoding: encoding),
                  isText(text) else { return nil }
            return text
        }
        if let text = String(data: data, encoding: .utf8), isText(text) { return text }

        let encodings: [UInt]
        if data.contains(0) {
            // 单字节和中文旧编码中的 NUL 不是正文；仅在 Unicode 范围内识别。
            encodings = [String.Encoding.utf16LittleEndian.rawValue,
                         String.Encoding.utf16BigEndian.rawValue,
                         String.Encoding.utf32LittleEndian.rawValue,
                         String.Encoding.utf32BigEndian.rawValue]
        } else {
            encodings = [CFStringEncodings.GB_18030_2000, .big5].map {
                CFStringConvertEncodingToNSStringEncoding(CFStringEncoding($0.rawValue))
            }
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

    private static func isText(_ text: String) -> Bool {
        // 保留制表、换行、换页和回车；拒绝二进制控制字符。
        !text.unicodeScalars.contains {
            ($0.value < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D].contains($0.value))
                || $0.value == 0x7F
        }
    }
}
