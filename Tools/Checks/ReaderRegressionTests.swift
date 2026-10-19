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
        let split = ChapterSplitter.split("第 1 章\n作者写的标题必须保留\n\n第一章 开始\n正文一\n\n第二章 继续\n正文二")
        try expect(split.chapters.map(\.text).joined().contains("第 1 章"), "Author heading was deleted")
        try expect(ChapterSplitter.split("第一章 开始\n正文一\n\n第二章 继续\n正文二").fromHeadings, "Heading pattern failed")
        print("PASS: Unicode offsets, exact chapter reads, text decoding and author text preservation")

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
        print("PASS: ordered snapshots and explicit write errors")
    }
}
