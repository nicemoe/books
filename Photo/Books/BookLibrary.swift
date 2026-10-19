import Foundation
import Observation

private struct BookIndex: Codable {
    var books: [Book] = []
    var settings = ReaderSettings()
    /// 书架布局是书架的偏好，不属于阅读设置，所以单独放一层。
    /// 默认列表：书多起来之后一屏能看到的书名多得多，封面本来就只是配色块。
    var shelfLayout: ShelfLayout = .list
    /// 全局外观。原来在相册那边的数据仓库里，拆成独立 App 后归到这儿。
    var appearance: AppTheme = .system

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        books = try c.decode([Book].self, forKey: .books)
        settings = try c.decodeIfPresent(ReaderSettings.self, forKey: .settings) ?? ReaderSettings()
        shelfLayout = try c.decodeIfPresent(ShelfLayout.self, forKey: .shelfLayout) ?? .list
        appearance = try c.decodeIfPresent(AppTheme.self, forKey: .appearance) ?? .system
    }

    enum CodingKeys: String, CodingKey { case books, settings, shelfLayout, appearance }
}

@MainActor
@Observable
final class BookLibrary {

    private(set) var books: [Book] = []
    var settings = ReaderSettings() {
        didSet { scheduleSave() }
    }
    var shelfLayout: ShelfLayout = .list {
        didSet { scheduleSave() }
    }
    var appearance: AppTheme = .system {
        didSet { scheduleSave() }
    }

    /// 导入进度。总数是开工前就数好的——一次丢一千本进来，
    /// 只显示「正在解析《某某》」的话，人不知道还要等多久。
    struct ImportProgress {
        var done: Int
        var total: Int
        var title: String

        var ratio: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// nil 表示没有在导入
    private(set) var importing: ImportProgress?

    /// 正在扫书库。挡住重入，见 importLooseFiles。
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var isImporting = false
    private(set) var isAvailable = false
    var operationError: String?
    private(set) var contentRevision: UInt64 = 0

    enum LibraryError: LocalizedError {
        case unavailable, busy, missingBook, invalidChapters
        var errorDescription: String? {
            switch self {
            case .unavailable: return "书库未能读取，已停止修改，原文件保持不动"
            case .busy: return "书库正在处理文件，请等待当前操作完成"
            case .missingBook: return "这本书已不存在"
            case .invalidChapters: return "章节索引损坏或与正文不一致"
            }
        }
    }

    private func requireEditable() throws {
        guard isAvailable else { throw LibraryError.unavailable }
        guard !isScanning, !isImporting else { throw LibraryError.busy }
    }

    /// 手上摊开的那本书的章节表。一次只留一本——人不会同时读两本，
    /// 而每本几百 KB，全留着就等于把搬出去的东西又搬回内存里。
    private var openBook: (id: UUID, chapters: [ChapterMeta])?

    init() {
        load()
    }

    // MARK: 读写

    private func load() {
        do {
            try BookPaths.prepare()
            if FileManager.default.fileExists(atPath: BookPaths.indexFile.path) {
                let data = try Data(contentsOf: BookPaths.indexFile)
                let index = try Coders.makeDecoder().decode(BookIndex.self, from: data)
                guard Set(index.books.map(\.id)).count == index.books.count,
                      index.books.allSatisfy({ !$0.sourceName.isEmpty
                        && !$0.sourceName.hasPrefix("/")
                        && !$0.sourceName.split(separator: "/").contains("..") }) else {
                    throw LibraryError.invalidChapters
                }
                books = index.books
                settings = index.settings
                shelfLayout = index.shelfLayout
                appearance = index.appearance
            }
            isAvailable = true
        } catch {
            operationError = "无法打开书库：\(error.localizedDescription)"
        }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveRevision: UInt64 = 0
    @ObservationIgnored private lazy var writer = SnapshotWriter(url: BookPaths.indexFile)

    private func scheduleSave() {
        guard isAvailable else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard isAvailable else { return }
        saveTask?.cancel()
        saveRevision += 1
        let revision = saveRevision
        let snapshot = BookIndex.make(books: books, settings: settings, shelfLayout: shelfLayout, appearance: appearance)
        let writer = writer
        Task { [weak self] in
            do { try await writer.write(snapshot, revision: revision) }
            catch { self?.operationError = "保存书库失败：\(error.localizedDescription)" }
        }
    }

    // MARK: 查询

    var sortedBooks: [Book] {
        // 最近读过的排前面，没读过的按加入时间
        books.sorted { a, b in
            let ka = max(a.progress.updatedAt, a.addedAt)
            let kb = max(b.progress.updatedAt, b.addedAt)
            return ka > kb
        }
    }

    func book(_ id: UUID) -> Book? { books.first { $0.id == id } }

    func chapters(of bookID: UUID) async throws -> [ChapterMeta] {
        guard isAvailable else { throw LibraryError.unavailable }
        if let openBook, openBook.id == bookID { return openBook.chapters }
        guard let book = book(bookID) else { throw LibraryError.missingBook }
        let stored: [ChapterMeta]
        if FileManager.default.fileExists(atPath: BookPaths.chapterFile(for: bookID).path) {
            stored = try await Task.detached(priority: .userInitiated) {
                var list = try Self.readChapters(bookID: bookID)
                if book.positionVersion == 0 {
                    for i in list.indices {
                        list[i].characterCount = try Self.chapterText(fileName: book.sourceName, chapter: list[i]).utf16.count
                    }
                    try Self.writeChapters(list, for: bookID)
                }
                return list
            }.value
        } else {
            try requireEditable()
            isScanning = true
            defer { isScanning = false }
            stored = try await rebuildChapters(for: book)
        }
        try Task.checkCancellation()
        guard let i = books.firstIndex(where: { $0.id == bookID }), books[i].sourceName == book.sourceName else {
            throw LibraryError.missingBook
        }
        guard !stored.isEmpty, stored.enumerated().allSatisfy({
            $0.offset == $0.element.index && $0.element.byteOffset >= 0 && $0.element.byteLength > 0
        }) else { throw LibraryError.invalidChapters }
        openBook = (bookID, stored)
        if books[i].sourceModifiedAt == nil {
            let values = try BookPaths.file(named: book.sourceName).resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values.contentModificationDate else { throw CocoaError(.fileReadUnknown) }
            books[i].sourceModifiedAt = modified.timeIntervalSince1970
            saveNow()
        }
        if books[i].positionVersion == 0 {
            books[i].positionVersion = 1
            books[i].totalCharacters = stored.reduce(0) { $0 + $1.characterCount }
            books[i].progress.charactersBefore = stored.prefix(max(0, books[i].progress.chapterIndex)).reduce(0) { $0 + $1.characterCount }
            saveNow()
        }
        return stored
    }

    func chapterText(bookID: UUID, index: Int) throws -> String {
        guard let book = book(bookID), let openBook, openBook.id == bookID,
              openBook.chapters.indices.contains(index) else { throw LibraryError.invalidChapters }
        return try Self.chapterText(fileName: book.sourceName, chapter: openBook.chapters[index])
    }

    nonisolated static func chapterText(fileName: String, chapter: ChapterMeta) throws -> String {
        guard !fileName.isEmpty else { throw LibraryError.invalidChapters }
        return try BookText.read(BookPaths.file(named: fileName), offset: chapter.byteOffset, length: chapter.byteLength)
    }

    // MARK: 导入

    enum ImportError: LocalizedError {
        case unsupported(String)
        case decodeFailed
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return "暂不支持 .\(ext) 格式，目前支持 TXT 和 EPUB"
            case .decodeFailed:         return "文件编码无法识别，可能已损坏"
            case .empty:                return "文件里没有可阅读的内容"
            }
        }
    }

    @discardableResult
    func importBook(from url: URL) async throws -> Book {
        try requireEditable()
        isImporting = true
        defer { isImporting = false }
        return try await performImport(from: url)
    }

    private func performImport(from url: URL) async throws -> Book {
        let ext = url.pathExtension.lowercased()
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        // 批量导入时总数由调用方先数好；单本进来的自己开一个 1/1
        let standalone = (importing == nil)
        if standalone { importing = ImportProgress(done: 0, total: 1, title: fallbackTitle) }
        else { importing?.title = fallbackTitle }
        defer {
            importing?.done += 1
            if standalone { importing = nil }
        }

        // 从「文件」App 拿到的是受保护的 URL，必须成对开关
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value

        // 解析放后台，长篇 TXT 的正则切分很吃 CPU
        let parsed: (title: String, author: String,
                     chapters: [ParsedChapter], fromHeadings: Bool)
        switch ext {
        case "txt":
            parsed = try await Task.detached(priority: .userInitiated) {
                guard let text = TextDecoding.decode(data) else { throw ImportError.decodeFailed }
                let split = ChapterSplitter.split(text)
                guard !split.chapters.isEmpty else { throw ImportError.empty }
                return (fallbackTitle, "", split.chapters, split.fromHeadings)
            }.value
        case "epub":
            parsed = try await Task.detached(priority: .userInitiated) {
                let result = try EpubParser.parse(data, fallbackTitle: fallbackTitle)
                // epub 的章节是照目录文件分的，那本来就是作者划的章
                return (result.title, result.author, result.chapters, true)
            }.value
        default:
            throw ImportError.unsupported(ext)
        }

        guard !parsed.chapters.isEmpty else { throw ImportError.empty }

        // 落盘：整本拼成一个 UTF-8 文件，章节只在索引里记字节范围。
        //
        // 原来是每章一个文件，一本 500 章的书就是 500 次写盘、500 次建目录；
        // 一次导一千本，光文件系统调用就几十万次——之前「解析很久」和那次
        // 启动看门狗闪退，大头都在这儿。现在一本书一次写盘。
        let chapters = parsed.chapters
        let stem = FileNames.unique(
            FileNames.sanitize(parsed.title),
            taken: Set(books.map { ($0.sourceName as NSString).deletingPathExtension }))

        let bookID = UUID()
        let built = try await Task.detached(priority: .userInitiated) {
            let made = try BookDisk.writeText(chapters: chapters, stem: stem, replacing: url)
            try Self.writeChapters(made.metas, for: bookID)
            try BookDisk.finishConversion(source: url, name: made.name)
            return made
        }.value

        let book = Book(id: bookID,
                        title: parsed.title,
                        sourceName: built.name,
                        textBytes: built.bytes,
                        sourceModifiedAt: built.modifiedAt,
                        positionVersion: 1,
                        author: parsed.author,
                        format: ext == "epub" ? .epub : .txt,
                        chapterCount: built.metas.count,
                        hasRealChapters: parsed.fromHeadings,
                        splitVersion: ChapterSplitter.version,
                        totalCharacters: built.characters,
                        colorIndex: Int(UInt(bitPattern: parsed.title.hashValue) % UInt(Theme.paletteHex.count)))

        books.append(book)
        saveNow()
        return book
    }

    /// 网页端上传用：直接给数据和文件名
    @discardableResult
    func importBook(data: Data, fileName: String) async throws -> Book {
        // 临时文件放进一个独有的子目录，文件名保持原样。
        //
        // 原来是拿 UUID 当前缀直接拼在文件名前面防重名，但书名正是从文件名
        // 取的，于是从网页传上来的书全都叫「<一长串 UUID>-书名」。
        // 换成用目录隔离，重名照样避得开，文件名不用动。
        let box = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: box) }

        let temp = box.appendingPathComponent((fileName as NSString).lastPathComponent)
        try data.write(to: temp, options: .atomic)
        return try await importBook(from: temp)
    }

    /// 一次导一批。总数先摆出来，进度浮层才有「几分之几」可显示——
    /// 一次选一百本却只看到「正在解析《某某》」，人不知道还要等多久。
    @discardableResult
    func importBooks(from urls: [URL]) async -> (ok: Int, failures: [String]) {
        guard !urls.isEmpty else { return (0, []) }
        do { try requireEditable() }
        catch { return (0, [error.localizedDescription]) }
        isImporting = true
        defer { isImporting = false }
        importing = ImportProgress(done: 0, total: urls.count, title: "")
        defer { importing = nil }

        var ok = 0
        var failures: [String] = []
        for url in urls {
            // 「文件」选取器是 asCopy 拿的，系统先把文件拷进临时目录再给 URL，
            // 那份拷贝的主人就是我们。导完（成了也好、报错也好）就该收掉——
            // 一次选一千本小说不收，就是一千份副本堆在临时目录里等系统哪天来清。
            defer { Self.discardTempCopy(url) }
            do {
                try await performImport(from: url)
                ok += 1
            } catch {
                // 带上文件名，一次选多本时才知道是哪本没进来
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return (ok, failures)
    }

    /// 收掉系统交给我们的那份临时拷贝。
    ///
    /// 只碰临时目录里的东西。扫书库那条路也走 importBook，但传进去的 URL
    /// 指着 Books 里的正主——那是书本身，删了就没了。
    nonisolated private static func discardTempCopy(_ url: URL) {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(tmp + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 收书库里还没收过的书。
    ///
    /// 「哪些是新的」是拿索引对出来的：每本书都记着自己的正文文件叫什么
    /// （sourceName），书库里对不上号的就是新拖进来的。不用比文件数——
    /// 比数不可靠，删一个加一个数字还一样。
    func importLooseFiles() async -> Int {
        // 两个触发点（视图首次出现、从后台切回前台）可能挨着来。不挡一下的话
        // 两次扫描会看到同一批新文件，各自导一遍，同一本书出现两条。
        guard isAvailable, !isScanning, !isImporting else { return 0 }
        isScanning = true
        defer { isScanning = false }

        let known = Set(books.map(\.sourceName).filter { !$0.isEmpty }.map { $0.lowercased() })
        // 扫盘甩到后台：一千个文件走一遍目录树也要点时间
        let all: [String]
        do { all = try await Task.detached(priority: .utility) { try Self.scanLibrary() }.value }
        catch { operationError = error.localizedDescription; return 0 }
        let fresh = all.filter { !known.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return 0 }

        // 先把总数摆出来再开工，不然一千本书就是干等着，不知道到哪了
        importing = ImportProgress(done: 0, total: fresh.count, title: "")
        defer { importing = nil }

        var saved = 0
        for name in fresh.sorted() {
            let url = BookPaths.file(named: name)
            do { _ = try await performImport(from: url); saved += 1 }
            catch { operationError = "\(name)：\(error.localizedDescription)"; break }
        }
        return saved
    }

    /// 该重拆的书重拆一遍：在访达里改过的，以及按老规则拆的。
    ///
    /// 章节记的是字节范围，而正文文件就摆在共享目录里，人随时能打开改两笔。
    /// 一改，后面每一章的偏移就整体错位，而且是静悄悄地错——点开某一章，
    /// 读出来是上一章的半句话。所以每次对账都拿文件大小校一下，对不上就重拆。
    ///
    /// 阅读进度和书签留着：那是人自己的东西，不是从文件生成的。章数变少了
    /// 就把进度夹回范围内，总比整本回到第一页强。
    @discardableResult
    func refreshEdited() async -> Int {
        // 和 importLooseFiles 共用一把锁：两个触发点挨着来的话，
        // 后一次会看到前一次还没写回 textBytes 的书，白重拆一遍。
        guard isAvailable, !isScanning, !isImporting else { return 0 }
        isScanning = true
        defer { isScanning = false }

        let sizes: [String: BookDisk.FileStamp]
        do { sizes = try await Task.detached(priority: .utility) { try BookDisk.fileStamps() }.value }
        catch { operationError = error.localizedDescription; return 0 }
        let stale: [(id: UUID, name: String)] = books.compactMap { book in
            guard !book.sourceName.isEmpty else { return nil }
            // 一、分章规则比这本书拆的时候新了。
            //
            // 章节表是导入那一刻算出来存下的，规则改进了它不会自己变好。
            // 头一版规则其实整个编译不过，所有书都是按字数硬切的，
            // 标题全是「第 N 节」——那一批全靠这条捞回来。
            if book.format == .txt && book.splitVersion < ChapterSplitter.version { return (book.id, book.sourceName) }
            // 二、文件在电脑上被改过，偏移全不作数了
            guard book.textBytes > 0,
                  let stamp = sizes[book.sourceName.lowercased()],
                  stamp.bytes != book.textBytes || (book.sourceModifiedAt != nil && stamp.modifiedAt != book.sourceModifiedAt)
            else { return nil }
            return (book.id, book.sourceName)
        }
        guard !stale.isEmpty else { return 0 }

        importing = ImportProgress(done: 0, total: stale.count, title: "")
        defer { importing = nil }

        var done = 0
        for (id, name) in stale {
            // 每轮都重新找一遍：这中间 await 过，books 可能已经变了
            guard let book = book(id), book.sourceName == name else { continue }
            importing?.title = book.title
            let rebuilt: [ChapterMeta]
            do { rebuilt = try await rebuildChapters(for: book) }
            catch { operationError = "\(book.title)：\(error.localizedDescription)"; break }
            importing?.done += 1
            guard let j = books.firstIndex(where: { $0.id == id }) else { continue }
            // 章少了的话，进度可能指着一章已经不存在的地方，夹回范围内
            if books[j].progress.chapterIndex >= rebuilt.count {
                books[j].progress = ReadingProgress(
                    chapterIndex: max(0, rebuilt.count - 1), updatedAt: books[j].progress.updatedAt)
            }
            done += 1
        }
        if done > 0 { saveNow() }
        return done
    }

    /// 照着正文重拆一遍，章节表跟着更新。
    ///
    /// 三种情况会走到这儿：文件在访达里被改过、章节表丢了（内部目录被清、
    /// 从旧版本升上来）、以及第一次打开一本还没有章节表的书。
    /// 三种都是同一件事——正文才是真的，章节表照着它重算。
    @discardableResult
    private func rebuildChapters(for book: Book) async throws -> [ChapterMeta] {
        let name = book.sourceName
        guard !name.isEmpty else { throw LibraryError.invalidChapters }
        let bookID = book.id
        let (built, fromHeadings) = try await Task.detached(priority: .userInitiated) {
            let url = BookPaths.file(named: name)
            let data = try Data(contentsOf: url)
            guard let text = TextDecoding.decode(data) else { throw ImportError.decodeFailed }
            let split = ChapterSplitter.split(text)
            guard !split.chapters.isEmpty else { throw ImportError.empty }
            let made = try BookDisk.writeText(chapters: split.chapters,
                                             stem: (name as NSString).deletingPathExtension, replacing: url)
            try Self.writeChapters(made.metas, for: bookID)
            return (made, split.fromHeadings)
        }.value
        guard let i = books.firstIndex(where: { $0.id == bookID }), books[i].sourceName == name else {
            throw LibraryError.missingBook
        }
        books[i].sourceName = built.name
        books[i].textBytes = built.bytes
        books[i].sourceModifiedAt = built.modifiedAt
        books[i].positionVersion = 1
        books[i].chapterCount = built.metas.count
        books[i].hasRealChapters = fromHeadings
        books[i].splitVersion = ChapterSplitter.version
        books[i].totalCharacters = built.characters
        let chapter = min(max(0, books[i].progress.chapterIndex), built.metas.count - 1)
        books[i].progress.chapterIndex = chapter
        books[i].progress.characterOffset = min(max(0, books[i].progress.characterOffset), built.metas[chapter].characterCount)
        books[i].progress.charactersBefore = built.metas.prefix(chapter).reduce(0) { $0 + $1.characterCount }
        if openBook?.id == bookID { openBook = (bookID, built.metas) }
        contentRevision += 1
        saveNow()
        return built.metas
    }

    // MARK: 章节表的读写

    nonisolated private static func writeChapters(_ list: [ChapterMeta], for bookID: UUID) throws {
        try Coders.makeEncoder().encode(list).write(to: BookPaths.chapterFile(for: bookID), options: .atomic)
    }

    nonisolated private static func readChapters(bookID: UUID) throws -> [ChapterMeta] {
        try Coders.makeDecoder().decode([ChapterMeta].self, from: Data(contentsOf: BookPaths.chapterFile(for: bookID)))
    }

    /// 正文文件在书库里被删掉了，书也跟着走。
    ///
    /// 那个文件就是这本书本身，索引里存的偏移全指着它。文件没了，
    /// 剩下的章节目录只是一堆指向空气的字节范围，点开是白的。
    ///
    /// sourceName 是空串的跳过：那种书压根没记文件是哪个，
    /// 无从判断在不在，不能拿「找不到」当「被删了」。
    @discardableResult
    func pruneMissingSources() async -> Int {
        guard isAvailable, !isScanning, !isImporting else { return 0 }
        isScanning = true
        defer { isScanning = false }
        let names: [String]
        do { names = try await Task.detached(priority: .utility) { try Self.scanLibrary() }.value }
        catch { operationError = error.localizedDescription; return 0 }
        let onDisk = Set(names.map { $0.lowercased() })
        let doomed = books.filter { !$0.sourceName.isEmpty
            && !onDisk.contains($0.sourceName.lowercased()) }
        guard !doomed.isEmpty else { return 0 }

        let doomedIDs = Set(doomed.map(\.id))
        for id in doomedIDs {
            do { try BookDisk.removeIfPresent(BookPaths.chapterFile(for: id)) }
            catch { operationError = error.localizedDescription; return 0 }
        }
        if let openBook, doomedIDs.contains(openBook.id) { self.openBook = nil }
        books.removeAll { doomedIDs.contains($0.id) }
        saveNow()
        return doomed.count
    }

    nonisolated private static func scanLibrary() throws -> [String] {
        try BookDisk.scanLibrary()
    }

    // MARK: 全文搜索

    struct SearchHit: Identifiable, Hashable {
        var id = UUID()
        var chapterIndex: Int
        var chapterTitle: String
        /// 命中位置在章内的字符偏移，跳转时直接用
        var offset: Int
        /// 命中处上下文，关键词用 【】 标出来
        var snippet: String
    }

    /// 逐章读文件搜索。整本几百万字，必须在后台跑，而且要能被取消——
    /// 用户还在打字时上一次搜索就该停下，否则会积压一堆任务。
    nonisolated func search(fileName: String, chapters: [ChapterMeta],
                            keyword: String, limit: Int = 200) async throws -> [SearchHit] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 1 else { return [] }

        var hits: [SearchHit] = []
        for meta in chapters {
            try Task.checkCancellation()

            let text = try Self.chapterText(fileName: fileName, chapter: meta)
            guard !text.isEmpty else { continue }

            var cursor = text.startIndex
            while let found = text.range(of: key, options: .caseInsensitive, range: cursor..<text.endIndex) {
                try Task.checkCancellation()
                let offset = NSRange(found, in: text).location

                let lead = text.index(found.lowerBound, offsetBy: -18, limitedBy: text.startIndex) ?? text.startIndex
                let tail = text.index(found.upperBound, offsetBy: 18, limitedBy: text.endIndex) ?? text.endIndex
                let snippet = (String(text[lead..<found.lowerBound])
                               + "【" + String(text[found]) + "】"
                               + String(text[found.upperBound..<tail]))
                    .replacingOccurrences(of: "\n", with: " ")

                hits.append(SearchHit(chapterIndex: meta.index,
                                      chapterTitle: meta.title,
                                      offset: offset,
                                      snippet: snippet))
                if hits.count >= limit { return hits }

                cursor = found.upperBound
            }
        }
        return hits
    }

    // MARK: 修改

    func updateProgress(bookID: UUID, chapterIndex: Int, characterOffset: Int) {
        guard isAvailable, chapterIndex >= 0, characterOffset >= 0,
              let i = books.firstIndex(where: { $0.id == bookID }),
              chapterIndex < books[i].chapterCount else { return }
        // 书架上那个百分比要「这一章之前累计多少字」。章节表正好在手上，
        // 顺手加一遍存住，省得画书架时为了一个百分比去读全书的章节表。
        let before: Int
        if let openBook, openBook.id == bookID, chapterIndex < openBook.chapters.count {
            before = openBook.chapters.prefix(chapterIndex).reduce(0) { $0 + $1.characterCount }
        } else {
            before = books[i].progress.charactersBefore
        }
        books[i].progress = ReadingProgress(chapterIndex: chapterIndex,
                                            characterOffset: characterOffset,
                                            charactersBefore: before,
                                            updatedAt: Date())
        scheduleSave()
    }

    // MARK: 书签

    /// 当前页是否已经有书签。按「同一章 + 偏移落在本页范围内」判断，
    /// 而不是要求偏移完全相等——排版一变，同一句话的偏移就不同了。
    func bookmark(bookID: UUID, chapter: Int, pageRange: Range<Int>) -> Bookmark? {
        book(bookID)?.bookmarks.first {
            $0.chapterIndex == chapter && pageRange.contains($0.characterOffset)
        }
    }

    @discardableResult
    func addBookmark(bookID: UUID, chapter: Int, offset: Int, title: String, snippet: String) -> Bookmark? {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return nil }
        let mark = Bookmark(chapterIndex: chapter,
                            characterOffset: offset,
                            chapterTitle: title,
                            snippet: snippet)
        books[i].bookmarks.append(mark)
        saveNow()
        return mark
    }

    func removeBookmark(bookID: UUID, markID: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].bookmarks.removeAll { $0.id == markID }
        saveNow()
    }

    /// 书签列表：新加的排前面
    func bookmarks(bookID: UUID) -> [Bookmark] {
        (book(bookID)?.bookmarks ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: 修改

    func rename(bookID: UUID, to title: String) throws {
        try requireEditable()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { throw LibraryError.missingBook }
        let old = books[i].sourceName
        let name = FileNames.sanitize(trimmed) + ".txt"
        if name != old {
            try FileManager.default.moveItem(at: BookPaths.file(named: old), to: BookPaths.file(named: name))
        }
        books[i].title = trimmed
        books[i].sourceName = name
        saveNow()
    }

    func delete(bookID: UUID) throws {
        try requireEditable()
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { throw LibraryError.missingBook }
        let book = books[i]
        try BookDisk.removeIfPresent(BookPaths.file(named: book.sourceName))
        books.remove(at: i)
        if openBook?.id == bookID { openBook = nil }
        saveNow()
        try BookDisk.removeIfPresent(BookPaths.chapterFile(for: bookID))
    }

}

private extension BookIndex {
    static func make(books: [Book], settings: ReaderSettings,
                     shelfLayout: ShelfLayout, appearance: AppTheme) -> BookIndex {
        var index = BookIndex()
        index.books = books
        index.settings = settings
        index.shelfLayout = shelfLayout
        index.appearance = appearance
        return index
    }
}
