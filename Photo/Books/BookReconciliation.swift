import Foundation

/// Decide work from one directory snapshot before mutating any book or file.
enum BookReconciliation {
    struct File {
        let name: String
        let stamp: BookFileState.Stamp
    }

    struct IndexedBook {
        let id: UUID
        let name: String
        let bytes: Int
        let modifiedAt: Double?
        let digest: String?
        let needsNewSplitRules: Bool
    }

    struct Plan {
        var added: [String] = []
        var removed: [UUID] = []
        var rebuilt: [UUID] = []
        var metadata: [UUID: BookFileState.Stamp] = [:]
        var failures: [String] = []
    }

    static func plan(books: [IndexedBook], files: [File],
                     digest: (String) throws -> String) throws -> Plan {
        var disk: [String: File] = [:]
        for file in files {
            guard disk.updateValue(file, forKey: file.name.lowercased()) == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        let known = Set(books.map { $0.name.lowercased() })
        var result = Plan()
        result.added = files.filter { !known.contains($0.name.lowercased()) }.map(\.name).sorted()
        for book in books {
            try Task.checkCancellation()
            guard let file = disk[book.name.lowercased()] else {
                result.removed.append(book.id)
                continue
            }
            if book.needsNewSplitRules || file.stamp.bytes != book.bytes {
                result.rebuilt.append(book.id)
                continue
            }
            guard let modifiedAt = book.modifiedAt else {
                result.rebuilt.append(book.id)
                continue
            }
            guard modifiedAt != file.stamp.modifiedAt else { continue }
            guard let expected = book.digest else {
                // Older indexes have no content identity. Rebuild once to establish it.
                result.rebuilt.append(book.id)
                continue
            }
            do {
                if try digest(file.name) == expected {
                    result.metadata[book.id] = file.stamp
                } else {
                    result.rebuilt.append(book.id)
                }
            } catch {
                result.failures.append("\(file.name)：\(error.localizedDescription)")
            }
        }
        return result
    }
}
