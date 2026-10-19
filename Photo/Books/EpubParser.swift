import Foundation

/// EPUB 解析：ZIP → container.xml → OPF → spine 顺序 → 每个 XHTML 抽成纯文本。
///
/// 只提取文字。小说不需要保留原排版和插图，纯文本反而让分页、字号、
/// 主题这些阅读设置能统一生效。
enum EpubParser {

    struct Result {
        var title: String
        var author: String
        var chapters: [ParsedChapter]
    }

    enum EpubError: LocalizedError {
        case missingContainer
        case missingOPF
        case emptySpine
        case invalidDocument(String)

        var errorDescription: String? {
            switch self {
            case .missingContainer: return "EPUB 缺少 META-INF/container.xml"
            case .missingOPF:       return "EPUB 找不到内容清单（OPF）"
            case .emptySpine:       return "EPUB 里没有可阅读的正文"
            case .invalidDocument(let path): return "EPUB 章节或清单损坏：\(path)"
            }
        }
    }

    static func parse(_ data: Data, fallbackTitle: String) throws -> Result {
        let entries = try MiniZip.entries(in: data)

        // 1. container.xml 指向 OPF
        guard let container = entries["META-INF/container.xml"] else { throw EpubError.missingContainer }
        let containerXML = try MiniZip.extract(container, from: data)
        guard let opfPath = try XMLScanner.attribute(in: containerXML, element: "rootfile", name: "full-path") else {
            throw EpubError.missingOPF
        }

        guard let opfEntry = entries[MiniZip.normalize(opfPath)] else { throw EpubError.missingOPF }
        let opfData = try MiniZip.extract(opfEntry, from: data)
        let opf = try OPF.parse(opfData)

        // OPF 里的 href 是相对它自己所在目录的
        let baseDirectory = (MiniZip.normalize(opfPath) as NSString).deletingLastPathComponent

        // 2. 按 spine 顺序取正文
        var chapters: [ParsedChapter] = []
        for idref in opf.spine {
            guard let href = opf.manifest[idref] else { throw EpubError.invalidDocument(idref) }
            let full = resolve(href, relativeTo: baseDirectory)
            guard let entry = entries[full] else { throw EpubError.invalidDocument(full) }
            let html = try MiniZip.extract(entry, from: data)

            let text = try HTMLText.plainText(from: html)
            guard !text.isEmpty else { continue }

            let title = try HTMLText.firstHeading(from: html)
                ?? firstLineAsTitle(text)
                ?? "第 \(chapters.count + 1) 章"
            // text 是整页 HTML 抽出来的纯文本，标题那个 <h1> 也在里面，
            // 所以第一行本来就是标题，不用另外拼
            chapters.append(ParsedChapter(title: title, text: text))
        }

        guard !chapters.isEmpty else { throw EpubError.emptySpine }

        return Result(title: opf.title.isEmpty ? fallbackTitle : opf.title,
                      author: opf.author,
                      chapters: chapters)
    }

    private static func resolve(_ href: String, relativeTo directory: String) -> String {
        let cleaned = href.components(separatedBy: "#")[0]
            .removingPercentEncoding ?? href
        if directory.isEmpty { return MiniZip.normalize(cleaned) }
        return MiniZip.normalize((directory as NSString).appendingPathComponent(cleaned))
    }

    private static func firstLineAsTitle(_ text: String) -> String? {
        guard let line = text.split(separator: "\n").first else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        return trimmed
    }
}

// MARK: - 取单个属性

/// 从一小段 XML 里取出某个元素的某个属性（用来读 container.xml 的 full-path）
enum XMLScanner {
    static func attribute(in data: Data, element: String, name: String) throws -> String? {
        let delegate = AttributeDelegate(element: element.lowercased(), attribute: name.lowercased())
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { throw EpubParser.EpubError.invalidDocument("container.xml") }
        return delegate.value
    }
}

private final class AttributeDelegate: NSObject, XMLParserDelegate {
    private let element: String
    private let attribute: String
    var value: String?

    init(element: String, attribute: String) {
        self.element = element
        self.attribute = attribute
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String]) {
        guard value == nil else { return }
        let name = elementName.lowercased().components(separatedBy: ":").last ?? elementName
        guard name == element else { return }
        for (key, v) in attributes where key.lowercased() == attribute {
            value = v
            return
        }
    }
}

// MARK: - OPF

private struct OPF {
    var title = ""
    var author = ""
    /// id -> href
    var manifest: [String: String] = [:]
    /// spine 里的 idref 顺序
    var spine: [String] = []

    static func parse(_ data: Data) throws -> OPF {
        let delegate = OPFDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { throw EpubParser.EpubError.invalidDocument("OPF") }
        return delegate.result
    }
}

private final class OPFDelegate: NSObject, XMLParserDelegate {
    var result = OPF()
    private var capturing: String?
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String]) {
        let name = elementName.lowercased().components(separatedBy: ":").last ?? elementName

        switch name {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                result.manifest[id] = href
            }
        case "itemref":
            // linear="no" 一般是附录、封面，不进正文顺序
            if let idref = attributes["idref"], attributes["linear"]?.lowercased() != "no" {
                result.spine.append(idref)
            }
        case "title", "creator":
            capturing = name
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased().components(separatedBy: ":").last ?? elementName
        guard name == capturing else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "title", result.title.isEmpty { result.title = value }
        if name == "creator", result.author.isEmpty { result.author = value }
        capturing = nil
        buffer = ""
    }
}

// MARK: - HTML 转纯文本

enum HTMLText {

    static func plainText(from data: Data) throws -> String {
        guard let html = TextDecoding.decode(data) else { throw EpubParser.EpubError.invalidDocument("XHTML 编码") }
        return plainText(from: html)
    }

    static func plainText(from html: String) -> String {
        var s = html

        // 整段丢掉的元素
        for tag in ["script", "style", "head"] {
            s = s.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // 块级元素转成换行，否则所有段落会连成一坨
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(p|div|h[1-6]|li|tr|blockquote|section)\\s*>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])

        // 剩下的标签全部去掉
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        s = decodeEntities(s)

        // 逐行清理，顺便压掉空行
        let lines = s.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ")
                     .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }

    /// 用 h1~h3 作为章节标题
    static func firstHeading(from data: Data) throws -> String? {
        guard let html = TextDecoding.decode(data) else { throw EpubParser.EpubError.invalidDocument("XHTML 编码") }
        guard let range = html.range(of: "<h[1-3]\\b[^>]*>[\\s\\S]*?</h[1-3]>",
                                     options: [.regularExpression, .caseInsensitive]) else { return nil }
        let heading = plainText(from: String(html[range]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heading.isEmpty, heading.count <= 40 else { return nil }
        return heading
    }

    private static func decodeEntities(_ text: String) -> String {
        var s = text
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&apos;": "'", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
                     "&hellip;": "\u{2026}", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}"]
        for (key, value) in named {
            s = s.replacingOccurrences(of: key, with: value, options: .caseInsensitive)
        }
        // 数字实体
        s = replaceNumericEntities(in: s, pattern: "&#([0-9]{1,7});", radix: 10)
        s = replaceNumericEntities(in: s, pattern: "&#[xX]([0-9A-Fa-f]{1,6});", radix: 16)
        // &amp; 放最后，避免把 &amp;lt; 提前还原成 <
        return s.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    private static func replaceNumericEntities(in text: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let digits = ns.substring(with: match.range(at: 1))
            if let code = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
