import Foundation
import SwiftUI

// MARK: - 书

enum BookFormat: String, Codable {
    case txt
    case epub

    var label: String {
        switch self {
        case .txt:  return "TXT"
        case .epub: return "EPUB"
        }
    }
}

/// 章节元信息。正文不进内存，这里只留标题、字数，和它在正文文件里的字节范围。
///
/// 整本书是 Books 下的一个 UTF-8 文件，读某一章就是 seek 到 byteOffset、
/// 读 byteLength 个字节、按 UTF-8 解出来。偏移是拆分那一刻算好的，
/// 天然落在字符边界上，不存在把一个多字节字劈开的问题。
///
/// 这些不进 books.json——一本 1600 章的书光章节表就 270 KB，一千本就是
/// 270 MB，而它每次保存都要整个重写一遍。章节表按书单独存（见 BookPaths），
/// 打开哪本读哪本。
struct ChapterMeta: Identifiable, Codable, Hashable {
    /// index 本身就是这一章的身份，不用再发一个 UUID。
    ///
    /// 原来这里是个存下来的 UUID，编码出来占单章 168 字节里的 47——
    /// 全是为了满足 Identifiable，而列表里区分两章靠的本来就是章序。
    var id: Int { index }

    var index: Int
    var title: String
    var characterCount: Int
    /// 正文在文件里的起始字节
    var byteOffset: Int = 0
    /// 正文占多少字节
    var byteLength: Int = 0

    init(index: Int, title: String, characterCount: Int,
         byteOffset: Int = 0, byteLength: Int = 0) {
        self.index = index
        self.title = title
        self.characterCount = characterCount
        self.byteOffset = byteOffset
        self.byteLength = byteLength
    }

    /// 手写解码。Swift 合成的 Decodable 不拿属性默认值兜缺失的键，直接抛错——
    /// 加了字段之后旧的章节表会整个解不出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        characterCount = try c.decodeIfPresent(Int.self, forKey: .characterCount) ?? 0
        byteOffset = try c.decodeIfPresent(Int.self, forKey: .byteOffset) ?? 0
        byteLength = try c.decodeIfPresent(Int.self, forKey: .byteLength) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case index, title, characterCount, byteOffset, byteLength
    }
}

/// 阅读进度。
///
/// 存「章节 + 章内字符偏移」而不是页码：页码会随字号、行距、屏幕尺寸、
/// 翻页/滚动模式变化，字符偏移不会，换任何设置都能回到原来那句话。
struct ReadingProgress: Codable, Hashable {
    var chapterIndex: Int = 0
    var characterOffset: Int = 0
    /// 这一章之前累计多少字。书架上那个百分比要用。
    ///
    /// 本来是拿章节表现算的（把前面每章的字数加起来），但章节表已经不在
    /// 内存里了——为了画一个百分比去读一遍全书的章节表，太亏。这个数只有
    /// 翻章时才变，而翻章的时候章节表正好在手上，顺手算一下存住。
    var charactersBefore: Int = 0
    var updatedAt: Date = Date()

    init(chapterIndex: Int = 0, characterOffset: Int = 0,
         charactersBefore: Int = 0, updatedAt: Date = Date()) {
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.charactersBefore = charactersBefore
        self.updatedAt = updatedAt
    }

    /// 同样要手写：合成的解码碰上旧数据里没有 charactersBefore 会直接抛错
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapterIndex = try c.decodeIfPresent(Int.self, forKey: .chapterIndex) ?? 0
        characterOffset = try c.decodeIfPresent(Int.self, forKey: .characterOffset) ?? 0
        charactersBefore = try c.decodeIfPresent(Int.self, forKey: .charactersBefore) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// 书签。存章节 + 章内字符偏移，和阅读进度同一套定位方式，
/// 所以改字号、换翻页模式之后依然能跳回原来那句话。
struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var chapterIndex: Int
    var characterOffset: Int
    var chapterTitle: String
    /// 书签处的开头几十个字，方便在列表里认出来
    var snippet: String
    var createdAt: Date = Date()
}

struct Book: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    /// 正文文件在 Books 下的文件名，形如「斗破苍穹.txt」。
    ///
    /// 一本书就这一个文件，UTF-8，导入时转好码、归一化好。章节不再各存一份，
    /// 只在索引里记它在这个文件里的字节范围。
    ///
    /// 不直接拿 title 当文件名：书名可以重复、可以带 / : * 这些文件系统不认的
    /// 字符。这里存一份洗过、且和别的书不重名的，改书名时一起把文件改名。
    var sourceName: String = ""
    /// 正文文件的字节数。用来发现文件在访达里被改过——
    /// 大小对不上就说明索引里那套偏移已经不作数了，得重新拆一遍。
    var textBytes: Int = 0
    var sourceModifiedAt: Double?
    var sourceDigest: String?
    var positionVersion: Int = 0
    var author: String = ""
    var format: BookFormat
    var addedAt: Date = Date()
    /// 共多少章。章节表本身按书单独存，这里只留书架和目录标题要显示的那个数。
    var chapterCount: Int = 0
    /// 正文里认出真章节了吗。
    ///
    /// false 表示整本没有「第 X 章」这类标记，现在这些片是按字数切的——
    /// 那是内部分片，不是目录。目录该只给一条，不能拿编号去充数。
    var hasRealChapters: Bool = true
    /// 这本书是按哪一版分章规则拆的。
    ///
    /// 规则改进了，已经收进来的书不会自己变好——章节表是导入那一刻算出来
    /// 存下的。记一个版本号，对账时发现落后了就照新规则重拆一遍。
    /// 0 是「规则还没能用的那个年代」，那时候所有书都是按字数硬切的。
    var splitVersion: Int = 0
    var totalCharacters: Int = 0
    var progress = ReadingProgress()
    /// 封面色，按书名哈希取，避免每本书都长一样
    var colorIndex: Int = 0
    var bookmarks: [Bookmark] = []

    init(id: UUID = UUID(), title: String,
         sourceName: String = "", textBytes: Int = 0,
         sourceModifiedAt: Double? = nil, sourceDigest: String? = nil, positionVersion: Int = 0,
         author: String = "", format: BookFormat,
         addedAt: Date = Date(), chapterCount: Int = 0,
         hasRealChapters: Bool = true, splitVersion: Int = 0,
         totalCharacters: Int = 0,
         progress: ReadingProgress = ReadingProgress(), colorIndex: Int = 0,
         bookmarks: [Bookmark] = []) {
        self.id = id
        self.title = title
        self.sourceName = sourceName
        self.textBytes = textBytes
        self.sourceModifiedAt = sourceModifiedAt
        self.sourceDigest = sourceDigest
        self.positionVersion = positionVersion
        self.author = author
        self.format = format
        self.addedAt = addedAt
        self.chapterCount = chapterCount
        self.hasRealChapters = hasRealChapters
        self.splitVersion = splitVersion
        self.totalCharacters = totalCharacters
        self.progress = progress
        self.colorIndex = colorIndex
        self.bookmarks = bookmarks
    }

    /// 手写解码，全部 decodeIfPresent。
    /// Swift 合成的 Decodable 不拿属性默认值兜缺失的键，直接抛错——
    /// 那样每加一个字段，旧的 books.json 就解不出来，整个书架会被清空。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        textBytes = try c.decodeIfPresent(Int.self, forKey: .textBytes) ?? 0
        sourceModifiedAt = try c.decodeIfPresent(Double.self, forKey: .sourceModifiedAt)
        sourceDigest = try c.decodeIfPresent(String.self, forKey: .sourceDigest)
        positionVersion = try c.decodeIfPresent(Int.self, forKey: .positionVersion) ?? 0
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        format = try c.decodeIfPresent(BookFormat.self, forKey: .format) ?? .txt
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        chapterCount = try c.decodeIfPresent(Int.self, forKey: .chapterCount) ?? 0
        hasRealChapters = try c.decodeIfPresent(Bool.self, forKey: .hasRealChapters) ?? true
        splitVersion = try c.decodeIfPresent(Int.self, forKey: .splitVersion) ?? 0
        totalCharacters = try c.decodeIfPresent(Int.self, forKey: .totalCharacters) ?? 0
        progress = try c.decodeIfPresent(ReadingProgress.self, forKey: .progress) ?? ReadingProgress()
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
    }

    /// 书架上那行副标题里的「有多大」。
    ///
    /// 认出章节的报章数，认不出的报字数——那种书现在是按字数切成片的，
    /// 报「128 章」等于把内部分片说成了书的章节。
    var sizeText: String {
        guard hasRealChapters else {
            return totalCharacters >= 10_000
                ? String(format: "%.1f 万字", Double(totalCharacters) / 10_000)
                : "\(totalCharacters) 字"
        }
        return "\(chapterCount) 章"
    }

    /// 0...1
    var progressRatio: Double {
        guard totalCharacters > 0 else { return 0 }
        return min(1, max(0, (Double(progress.charactersBefore) + Double(progress.characterOffset))
                           / Double(totalCharacters)))
    }

    var progressText: String {
        guard chapterCount > 0 else { return "未开始" }
        if progressRatio <= 0 { return "未开始" }
        return String(format: "已读 %.0f%%", progressRatio * 100)
    }

}

// MARK: - 阅读设置

enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case paper      // 米白
    case eyecare    // 护眼绿
    case sepia      // 羊皮纸
    case gray       // 灰
    case night      // 夜间

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper:   return "白"
        case .eyecare: return "绿"
        case .sepia:   return "黄"
        case .gray:    return "灰"
        case .night:   return "夜"
        }
    }

    var background: Color {
        switch self {
        case .paper:   return Color(hex: 0xFBFBF9)
        case .eyecare: return Color(hex: 0xCCE8CF)
        case .sepia:   return Color(hex: 0xF5EBD9)
        case .gray:    return Color(hex: 0xCFD1CE)
        case .night:   return Color(hex: 0x121316)
        }
    }

    var text: Color {
        switch self {
        case .night: return Color(hex: 0x9AA0A8)
        default:     return Color(hex: 0x2B2A28)
        }
    }

    /// 工具栏等次要元素
    var secondary: Color {
        switch self {
        case .night: return Color(hex: 0x6B7079)
        default:     return Color(hex: 0x8A8781)
        }
    }

    var isDark: Bool { self == .night }
}

enum ReaderFont: String, Codable, CaseIterable, Identifiable {
    case system
    case serif
    case rounded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:  return "系统"
        case .serif:   return "宋体"
        case .rounded: return "圆体"
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .system:
            return .systemFont(ofSize: size)
        case .serif:
            let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
                .withDesign(.serif) ?? UIFont.systemFont(ofSize: size).fontDescriptor
            return UIFont(descriptor: descriptor, size: size)
        case .rounded:
            let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
                .withDesign(.rounded) ?? UIFont.systemFont(ofSize: size).fontDescriptor
            return UIFont(descriptor: descriptor, size: size)
        }
    }
}

enum ReadingMode: String, Codable, CaseIterable, Identifiable {
    case paged      // 点击左右翻页
    case scroll     // 上下滚动

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paged:  return "翻页"
        case .scroll: return "滚动"
        }
    }

    var icon: String {
        switch self {
        case .paged:  return "book"
        case .scroll: return "arrow.up.arrow.down"
        }
    }
}

/// 翻页效果。
///
/// 仿真卷曲交给系统的 UIPageViewController(.pageCurl)——它是硬件加速的，
/// 而且能跟手拖出卷角，自己用 SwiftUI 画不出这个效果。
enum PageAnimation: String, Codable, CaseIterable, Identifiable {
    case curl
    case slide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .curl:  return "仿真"
        case .slide: return "平移"
        }
    }

    var transitionStyle: UIPageViewController.TransitionStyle {
        switch self {
        case .curl:  return .pageCurl
        case .slide: return .scroll
        }
    }
}

/// 书架的展示方式
enum ShelfLayout: String, Codable, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "书封"
        case .list: return "列表"
        }
    }

    var icon: String {
        switch self {
        case .grid: return "books.vertical"
        case .list: return "list.bullet"
        }
    }
}

struct ReaderSettings: Codable, Hashable {
    var fontSize: Double = 16
    var lineSpacing: Double = 9
    var margin: Double = 22
    var font: ReaderFont = .system
    var theme: ReaderTheme = .paper
    var mode: ReadingMode = .paged
    var pageAnimation: PageAnimation = .curl
    /// 自动翻页的间隔（秒）
    var autoFlipInterval: Double = 8
    /// 阅读时的屏幕亮度。nil = 跟随系统，不去动它。
    var brightness: Double?

    static let fontSizeRange: ClosedRange<Double> = 13...30
    static let lineSpacingRange: ClosedRange<Double> = 2...20
    static let autoFlipRange: ClosedRange<Double> = 3...30

    init() {}

    /// 必须手写解码，全部用 decodeIfPresent 兜默认值。
    ///
    /// Swift 合成的 Decodable 不会拿属性默认值当缺失时的兜底——键不在就直接抛错。
    /// 那样每加一个新设置字段，旧的 books.json 都会解码失败，
    /// 连带整个 BookIndex 解不出来，用户的书架会被清空。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 16
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 9
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? 22
        font = try c.decodeIfPresent(ReaderFont.self, forKey: .font) ?? .system
        theme = try c.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? .paper
        mode = try c.decodeIfPresent(ReadingMode.self, forKey: .mode) ?? .paged
        pageAnimation = try c.decodeIfPresent(PageAnimation.self, forKey: .pageAnimation) ?? .curl
        autoFlipInterval = try c.decodeIfPresent(Double.self, forKey: .autoFlipInterval) ?? 8
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness)
        guard Self.fontSizeRange.contains(fontSize), Self.lineSpacingRange.contains(lineSpacing),
              Self.autoFlipRange.contains(autoFlipInterval), (0...80).contains(margin),
              brightness.map({ (0...1).contains($0) }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "阅读设置超出有效范围"))
        }
    }
}

extension ReaderSettings {
    struct Layout: Hashable {
        let fontSize: Double
        let lineSpacing: Double
        let margin: Double
        let font: ReaderFont
        let theme: ReaderTheme
    }
    var layout: Layout {
        Layout(fontSize: fontSize, lineSpacing: lineSpacing, margin: margin, font: font, theme: theme)
    }
}
