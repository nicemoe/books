import Foundation

/// 磁盘路径。放在数据仓库之外，服务端线程也能安全读取。
enum Paths {
    static let documents: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

}

/// App 内部目录。放索引、章节表这些「我们自己记账用」的东西。
///
/// 和 Documents 的分工：Documents 开了文件共享，访达里看得见、拖得动，
/// 那里只该放人自己的东西——一本一本的 txt。索引不是人的东西，它是
/// 我们怎么记账的实现细节，摆在书旁边只会让人误以为该管它，
/// 手改坏了还得连累阅读进度。
///
/// 原来试过留在 Documents 里、给文件打 BSD 的 immutable 标志（`chflags uchg`）
/// 让访达改不动。能work，但那是在补一个不该存在的问题——最省事的办法是
/// 它压根就不出现在那儿。
enum AppStore {

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base
    }()

    static func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    /// 从 Documents 搬一件东西进来。旧版本把它放在共享目录里，这里搬一次家。
    ///
    /// 目标已经在了就不动——搬过一次之后 Documents 那份如果又冒出来
    /// （从备份恢复、别的设备同步过来），也是旧的，不该盖掉现在这份。
    static func migrateFromDocuments(_ name: String, to target: URL) throws {
        let fm = FileManager.default
        let old = Paths.documents.appendingPathComponent(name)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: target.path) else { return }
        // 旧版本给索引上过 immutable 锁，锁着的文件搬不动，先摘掉
        try fm.setAttributes([.immutable: false], ofItemAtPath: old.path)
        try fm.moveItem(at: old, to: target)
    }

    /// 从 iCloud/iTunes 备份里排除。
    ///
    /// 给能重算的东西用——章节表丢了照着正文重拆就有，没必要让它把
    /// 用户的备份撑大。索引不用排除：阅读进度和书签只此一份，
    /// 换手机的时候恰恰是最该跟过去的。
    static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

/// JSON 编解码配置。日期统一用 ISO8601，换机、跨版本读写都不会歪。
enum Coders {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
