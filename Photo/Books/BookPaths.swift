import Foundation

/// 书在磁盘上怎么摆。
///
///     Documents/                 ← 访达里看得到的，只有人自己的东西
///       Books/
///         斗破苍穹.txt          ← 一本书就一个文件，UTF-8
///         三体.txt
///
///     Library/Application Support/   ← App 内部，访达里看不到
///       books.json              ← 书目 + 阅读进度 + 书签
///       Chapters/
///         <书的 id>.json        ← 这本书每章的标题 + 起始字节 + 长度
///
/// 分工是「这东西是谁的」：txt 是人的，索引和章节表是我们记账用的。
/// 索引摆在书旁边只会让人误以为该管它，手改坏了还连累阅读进度。
///
/// 一本书一个文件，不再按章拆成几百个小文件。
///
/// 拆成小文件的理由本来是「排版和内存要按章来」，但那只要求*读*的时候
/// 一章一章读，不要求*存*的时候一章一个文件。改成记字节范围之后，读一章
/// 就是 seek 到偏移读一段，一样按需，代价却小得多：一千本书从五十万个
/// 文件变成一千个。之前「导入解析很久」和那次启动看门狗闪退，大头就是
/// 这五十万次文件系统调用。
///
/// 编码在导入那一刻就统一成 UTF-8 了。GBK 也好、epub 也好，都只是文件
/// 从哪儿下载来的痕迹，不是想要的形态——收进来的时候一次收拾干净，
/// 后面所有偏移都指着同一种编码，不用再判断。
enum BookPaths {

    static let root = Paths.documents.appendingPathComponent("Books", isDirectory: true)
    static let indexFile = AppStore.file("books.json")

    static func file(named name: String) -> URL {
        root.appendingPathComponent(name)
    }

    /// 章节表放这儿，一本书一个文件。
    ///
    /// 不进 books.json，因为它太大又太不常变：一本 1600 章的书章节表就
    /// 270 KB，一千本 270 MB，而 books.json 每翻一页都要整个重写一遍——
    /// 一小时阅读能写掉几十 GB。分开之后 books.json 只剩书目和进度，
    /// 一千本约 460 KB，章节表只在打开那本书时读。
    ///
    /// 也不放 Documents：它是照着正文算出来的派生数据，不是人的东西，
    /// 访达里不该看见，丢了也能重拆。用 Application Support 而不是
    /// Caches——Caches 系统会挑时候清掉，清一次就是一千本书重拆一遍。
    static let chaptersRoot = AppStore.root.appendingPathComponent("Chapters", isDirectory: true)

    static func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: AppStore.root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: chaptersRoot, withIntermediateDirectories: true)
        try AppStore.migrateFromDocuments("books.json", to: indexFile)
        try AppStore.excludeFromBackup(chaptersRoot)
    }

    static func chapterFile(for bookID: UUID) -> URL {
        chaptersRoot.appendingPathComponent(bookID.uuidString + ".json")
    }
}

/// 文件名和目录名的清洗。
///
/// 不只是为了 iOS：这些文件迟早要从访达拖到 Windows 上去，所以按更严的
/// 那一套来——Windows 不认 \ / : * ? " < > |，也不许结尾是点或空格。
enum FileNames {

    static func sanitize(_ raw: String, limit: Int = 80) -> String {
        let banned = Set<Character>("\\/:*?\"<>|")
        var out = ""
        out.reserveCapacity(raw.count)
        for c in raw {
            if banned.contains(c) || c.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                out.append("_")
            } else {
                out.append(c)
            }
        }
        // 结尾的点和空格在 Windows 上会被悄悄吃掉，先去掉免得对不上
        if out.count > limit { out = String(out.prefix(limit)) }
        while let last = out.last, last == "." || last == " " { out.removeLast() }
        return out.isEmpty ? "未命名" : out
    }

    /// 在一堆已占用的名字里挑一个不重的：「斗破苍穹」「斗破苍穹 (2)」…
    /// 比较不分大小写——iOS 的文件系统不分，拷到 Windows 上也不分。
    static func unique(_ base: String, taken: Set<String>) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(base.lowercased()) else { return base }
        var n = 2
        while true {
            let candidate = "\(base) (\(n))"
            if !lowered.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }
}

