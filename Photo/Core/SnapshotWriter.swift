import Foundation

/// 单一写入者；旧任务晚到时不能覆盖已经提交的新快照。
actor SnapshotWriter {
    private let url: URL
    private var latestRevision: UInt64 = 0

    init(url: URL) { self.url = url }

    func write<Value: Encodable>(_ value: Value, revision: UInt64) throws {
        guard revision > latestRevision else { return }
        latestRevision = revision
        try Coders.makeEncoder().encode(value).write(to: url, options: .atomic)
    }
}
