import Foundation

struct TestFailure: Error { let message: String }
func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(message: message) }
}
func expectFailure(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch { return }
    throw TestFailure(message: message)
}

@main
struct ReaderRegressionTests {
    struct Snapshot: Codable, Sendable { let value: Int }

    static func main() async throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let epub = try Data(contentsOf: fixtures.appendingPathComponent("valid.epub"))
        let entries = try MiniZip.entries(in: epub)
        try expect(entries.count == 4, "ZIP directory entries missing")
        for entry in entries.values { _ = try MiniZip.extract(entry, from: epub) }
        let parsed = try EpubParser.parse(epub, fallbackTitle: "fixture")
        try expect(parsed.title == "测试书", "OPF metadata was not read")
        try expect(parsed.chapters.count == 2, "Short chapters were discarded")
        try expect(parsed.chapters[0].text == "短章", "Relative spine path failed")
        try expect(MiniZip.normalize("OPS/../Text/./chapter.xhtml") == "Text/chapter.xhtml", "Path normalization failed")
        try expect(MiniZip.crc32(Data("123456789".utf8)) == 0xCBF43926, "CRC32 mismatch")

        for name in ["bad-crc.epub", "missing-spine.epub", "bad-opf.epub", "oversize.epub", "truncated.epub"] {
            let data = try Data(contentsOf: fixtures.appendingPathComponent(name))
            try expectFailure("Malformed EPUB accepted: \(name)") {
                _ = try EpubParser.parse(data, fallbackTitle: "fixture")
            }
        }
        print("PASS: EPUB paths, short chapters, CRC, malformed XML, truncation and size limits")

        let text = "😀开头𠮷野家，正文\ne\u{301}结尾"
        let file = fixtures.appendingPathComponent("unicode.txt")
        try Data(text.utf8).write(to: file)
        try expect(try BookText.read(file, offset: 0, length: text.utf8.count) == text, "UTF-8 range read failed")
        let offset = (text as NSString).range(of: "正文").location
        try expect(BookText.snippet(text, at: offset, length: 2) == "正文", "UTF-16 bookmark offset mismatch")
        try expectFailure("Truncated chapter read accepted") {
            _ = try BookText.read(file, offset: 0, length: text.utf8.count + 1)
        }
        try expectFailure("Negative byte offset accepted") { _ = try BookText.read(file, offset: -1, length: 1) }
        try expect(TextDecoding.decode(Data([0x00, 0x01, 0x02])) == nil, "Binary bytes decoded as a novel")
        let utf32 = Data([0xFF, 0xFE, 0, 0, 0x2D, 0x4E, 0, 0])
        try expect(TextDecoding.decode(utf32) == "中", "UTF-32 BOM mistaken for UTF-16")
        let encodings = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: fixtures.appendingPathComponent("encodings.json")))
        for name in encodings.keys.sorted() {
            let bytes = try Data(contentsOf: fixtures.appendingPathComponent(name))
            let decoded = TextDecoding.decode(bytes)
            try expect(decoded == encodings[name], "Encoding mismatch: \(name), decoded: \(String(describing: decoded?.prefix(80)))")
        }
        for bytes: [UInt8] in [[0xEF, 0xBB, 0xBF, 0xFF], [0xFF, 0xFE, 0x2D],
                               [0x81], [0x81, 0x30, 0x81], [0xFF, 0xFF, 0xFF],
                               [0x41, 0x01, 0x42]] {
            try expect(TextDecoding.decode(Data(bytes)) == nil, "Malformed text accepted: \(bytes)")
        }
        print("PASS: GBK, GB18030, Big5, mixed-language and Unicode encoding fixtures")
        let split = ChapterSplitter.split("第 1 章\n作者写的标题必须保留\n\n第一章 开始\n正文一\n\n第二章 继续\n正文二")
        try expect(split.chapters.map(\.text).joined().contains("第 1 章"), "Author heading was deleted")
        try expect(ChapterSplitter.split("第一章 开始\n正文一\n\n第二章 继续\n正文二").fromHeadings, "Heading pattern failed")
        print("PASS: Unicode offsets, exact chapter reads, text decoding and author text preservation")

        // Reopening must not confuse a metadata-only change with a changed novel.
        let bookURL = fixtures.appendingPathComponent("file-state.txt")
        let original = Data("第一章\n原来的正文".utf8)
        try original.write(to: bookURL, options: .atomic)
        let recorded = try BookFileState.stamp(bookURL)
        let fingerprint = BookFileState.digest(original)
        let savedFingerprint = try Coders.makeEncoder().encode(fingerprint)
        try expect(try BookFileState.digest(bookURL) == Coders.makeDecoder().decode(String.self, from: savedFingerprint),
                   "Fingerprint changed after saving and reopening")
        let savedStamp = try Coders.makeEncoder().encode(recorded)
        try expect(try Coders.makeDecoder().decode(BookFileState.Stamp.self, from: savedStamp) == BookFileState.stamp(bookURL),
                   "Unchanged file stamp changed after index round trip")
        var cachedURL = bookURL
        _ = try cachedURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: recorded.modifiedAt + 10)], ofItemAtPath: bookURL.path)
        let touched = try BookFileState.stamp(cachedURL)
        try expect(touched.modifiedAt != recorded.modifiedAt, "File stamp reused cached modification date")
        try expect(try BookFileState.digest(bookURL) == fingerprint, "Metadata-only change invalidated chapter content")
        let edited = Data("第一章\n修改的正文".utf8)
        try expect(edited.count == original.count, "Same-size edit fixture is invalid")
        try edited.write(to: bookURL, options: .atomic)
        try expect(try BookFileState.digest(bookURL) != fingerprint, "Same-size content edit was ignored")
        try expect(try BookFileState.digest(bookURL) == BookFileState.digest(edited), "Streaming and import digests differ")
        print("PASS: persisted file stamps, fresh metadata, unchanged content and same-size edits")

        let stamp = BookFileState.Stamp(bytes: 120, modifiedAt: 1234.125)
        let indexed = (0..<1000).map { index in
            BookReconciliation.IndexedBook(id: UUID(), name: "book-\(index).txt",
                bytes: stamp.bytes, modifiedAt: stamp.modifiedAt, digest: "digest-\(index)", needsNewSplitRules: false)
        }
        let disk = indexed.map { BookReconciliation.File(name: $0.name, stamp: stamp) }
        for _ in 0..<3 {
            let unchanged = try BookReconciliation.plan(books: indexed, files: disk) { _ in
                throw TestFailure(message: "Unchanged book content was read during a foreground scan")
            }
            try expect(unchanged.added.isEmpty && unchanged.removed.isEmpty && unchanged.rebuilt.isEmpty
                       && unchanged.metadata.isEmpty && unchanged.failures.isEmpty,
                       "Reopening unchanged library scheduled work")
        }
        let currentStamp = BookFileState.Stamp(bytes: 120, modifiedAt: 5678)
        let changedDisk = [BookReconciliation.File(name: indexed[0].name, stamp: currentStamp),
                           BookReconciliation.File(name: indexed[1].name, stamp: currentStamp),
                           BookReconciliation.File(name: "new.txt", stamp: stamp)]
        let changes = try BookReconciliation.plan(books: Array(indexed.prefix(3)), files: changedDisk) { name in
            name == indexed[0].name ? "digest-0" : "changed"
        }
        try expect(changes.added == ["new.txt"] && changes.removed == [indexed[2].id]
                   && changes.rebuilt == [indexed[1].id] && changes.metadata[indexed[0].id] == currentStamp,
                   "Single snapshot failed to distinguish added, deleted, edited and touched books")
        let failedRead = try BookReconciliation.plan(books: [indexed[0]], files: [changedDisk[0]]) { _ in
            throw CocoaError(.fileReadNoPermission)
        }
        try expect(failedRead.failures.count == 1 && failedRead.rebuilt.isEmpty && failedRead.removed.isEmpty,
                   "Read failure was treated as a deletion or permission to rewrite")
        let oldRules = BookReconciliation.IndexedBook(id: UUID(), name: "old.txt", bytes: stamp.bytes,
            modifiedAt: stamp.modifiedAt, digest: "old", needsNewSplitRules: true)
        let migration = try BookReconciliation.plan(books: [oldRules], files: [.init(name: oldRules.name, stamp: stamp)]) { _ in "old" }
        try expect(migration.rebuilt == [oldRules.id], "Chapter rule migration was skipped")
        print("PASS: 1000-book repeated opens do no content reads; one snapshot separates every change type")

        let uploadText = "正文\r\n--boundary-not-a-separator\r\n结尾"
        let upload = Data(("--boundary\r\nContent-Disposition: form-data; name=\"files\"; filename=\"book.txt\"\r\n\r\n"
            + uploadText + "\r\n--boundary--\r\n").utf8)
        let parts = try Multipart.parse(body: upload, boundary: "boundary")
        try expect(parts.count == 1 && parts[0].data == Data(uploadText.utf8), "Multipart text was truncated")
        try expectFailure("Incomplete upload accepted") {
            _ = try Multipart.parse(body: Data(upload.dropLast(8)), boundary: "boundary")
        }
        try expectFailure("Invalid upload accepted") {
            _ = try Multipart.parse(body: Data("book text".utf8), boundary: "boundary")
        }
        print("PASS: multipart boundary validation and incomplete upload rejection")

        let saved = fixtures.appendingPathComponent("snapshots.json")
        let writer = SnapshotWriter(url: saved)
        try await writer.write(Snapshot(value: 2), revision: 2)
        try await writer.write(Snapshot(value: 1), revision: 1)
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: saved))
        try expect(snapshot.value == 2, "Old snapshot overwrote newer state")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in 3...100 {
                group.addTask { try await writer.write(Snapshot(value: revision), revision: UInt64(revision)) }
            }
            try await group.waitForAll()
        }
        snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: saved))
        try expect(snapshot.value == 100, "Concurrent snapshot order was lost")
        let unavailable = SnapshotWriter(url: fixtures.appendingPathComponent("missing/index.json"))
        do {
            try await unavailable.write(Snapshot(value: 1), revision: 1)
            throw TestFailure(message: "Write failure was ignored")
        } catch is CocoaError { }
        try FileManager.default.createDirectory(at: fixtures.appendingPathComponent("missing"), withIntermediateDirectories: true)
        try await unavailable.write(Snapshot(value: 1), revision: 1)
        let retried = try JSONDecoder().decode(Snapshot.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("missing/index.json")))
        try expect(retried.value == 1, "Failed write incorrectly consumed the snapshot revision")
        print("PASS: ordered snapshots and explicit write errors")
    }
}
