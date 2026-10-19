import Foundation

/// 文件操作集中在这里；失败向上抛出，不用空正文或空目录冒充成功。
enum BookDisk {
    struct FileStamp {
        let bytes: Int
        let modifiedAt: Double
    }

    struct WrittenBook {
        let metas: [ChapterMeta]
        let characters: Int
        let bytes: Int
        let name: String
        let modifiedAt: Double
    }

    static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }

    static func scanLibrary() throws -> [String] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var scanError: Error?
        guard let walker = FileManager.default.enumerator(at: BookPaths.root,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
            errorHandler: { _, error in scanError = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var names: [String] = []
        let prefix = BookPaths.root.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  ["txt", "epub"].contains(url.pathExtension.lowercased()),
                  url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            names.append(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
        }
        if let scanError { throw scanError }
        return names
    }

    static func fileStamps() throws -> [String: FileStamp] {
        var stamps: [String: FileStamp] = [:]
        for name in try scanLibrary() {
            let values = try BookPaths.file(named: name).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let bytes = values.fileSize, let date = values.contentModificationDate else {
                throw CocoaError(.fileReadUnknown)
            }
            stamps[name.lowercased()] = FileStamp(bytes: bytes, modifiedAt: date.timeIntervalSince1970)
        }
        return stamps
    }

    static func writeText(chapters: [ParsedChapter], stem: String, replacing source: URL) throws -> WrittenBook {
        guard !chapters.isEmpty else { throw BookLibrary.ImportError.empty }
        var blob = Data()
        var metas: [ChapterMeta] = []
        var characters = 0
        for (index, chapter) in chapters.enumerated() {
            let body = Data(chapter.text.utf8)
            let count = chapter.text.utf16.count
            metas.append(ChapterMeta(index: index, title: chapter.title, characterCount: count,
                                     byteOffset: blob.count, byteLength: body.count))
            blob.append(body)
            blob.append(contentsOf: [10, 10])
            characters += count
        }
        let fm = FileManager.default
        var name = stem + ".txt"
        var target = BookPaths.file(named: name)
        if target.standardizedFileURL != source.standardizedFileURL {
            var suffix = 2
            while fm.fileExists(atPath: target.path) {
                name = "\(stem) (\(suffix)).txt"
                target = BookPaths.file(named: name)
                suffix += 1
            }
        }
        try blob.write(to: target, options: .atomic)
        let values = try target.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modified = values.contentModificationDate else { throw CocoaError(.fileReadUnknown) }
        return WrittenBook(metas: metas, characters: characters, bytes: blob.count,
                           name: name, modifiedAt: modified.timeIntervalSince1970)
    }

    /// 只有正文和章节表均已写好后，才移除书库内被转换的源文件。
    static func finishConversion(source: URL, name: String) throws {
        let target = BookPaths.file(named: name).standardizedFileURL
        let source = source.standardizedFileURL
        guard source != target, source.path.hasPrefix(BookPaths.root.standardizedFileURL.path + "/") else { return }
        try FileManager.default.removeItem(at: source)
    }
}
