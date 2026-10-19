import Foundation
import UIKit
import Observation

/// WiFi 传输：启动本机 HTTP 服务，同局域网设备用浏览器上传小说、管理书架
@MainActor
@Observable
final class WiFiService {

    enum Status: Equatable {
        case stopped
        case starting
        case running(url: String)
        case failed(String)
    }

    private(set) var status: Status = .stopped
    private(set) var receivedCount = 0
    private(set) var lastEvent: String?

    private let server = HTTPServer()
    private let books: BookLibrary
    /// 上一次有人来访的时间。空闲自动停服要用。
    private var lastActivity = Date()
    private var idleWatch: Task<Void, Never>?
    private var startRevision = 0
    /// 没人来这么久就自己关掉。见 watchIdle。
    private static let idleLimit: TimeInterval = 20 * 60

    init(books: BookLibrary) {
        self.books = books
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var urlString: String? {
        if case .running(let url) = status { return url }
        return nil
    }

    // MARK: 开关

    func start() async {
        guard !isRunning, status != .starting else { return }
        startRevision += 1
        let revision = startRevision
        status = .starting
        receivedCount = 0
        lastEvent = nil

        guard let ip = NetworkInfo.localIPAddress() else {
            status = .failed("未检测到 WiFi 连接，请先连接无线网络")
            return
        }

        do {
            let port = try await server.start { [weak self] request in
                guard let self else { return .notFound }
                return await self.handle(request)
            }
            guard revision == startRevision else { return }
            status = .running(url: "http://\(ip):\(port)")
            // 服务只能在前台活着——App 一被挂起 NWListener 就没了，所以传输
            // 期间必须拦着屏幕自动锁。代价是这段时间屏幕一直亮着，很费电，
            // 所以下面盯着，没人用就自己关掉。
            UIApplication.shared.isIdleTimerDisabled = true
            lastActivity = Date()
            watchIdle()
        } catch {
            guard revision == startRevision else { return }
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        startRevision += 1
        idleWatch?.cancel()
        idleWatch = nil
        server.stop()
        status = .stopped
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// 没人用就把服务关掉。
    ///
    /// 开着传输的这段时间屏幕是被强制点亮的，这是整个 App 里最费电的状态——
    /// 传完了忘记关，一晚上就能把电耗光。所以盯一下：二十分钟没人来访就自己收。
    ///
    /// 两个条件都要满足才算「没人用」：
    ///
    /// - 二十分钟没有请求进来。网页那边开着的话会不停拉列表，
    ///   所以只要还有人在用，这个条件就不成立。
    /// - 手上没有连着的客户端。正在传一本很大的书时连接是在的，但那一个
    ///   请求要跑一会儿才完成——只看「最后一次请求什么时候」会把它掐断。
    ///
    /// 一分钟醒一次。这个频率本身的开销可以忽略，比屏幕多亮一分钟便宜得多。
    private func watchIdle() {
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, self.isRunning else { return }
                guard !self.server.hasActiveConnections,
                      Date().timeIntervalSince(self.lastActivity) > Self.idleLimit else { continue }
                self.stop()
                self.lastEvent = "闲置太久，已自动关闭传输"
                return
            }
        }
    }

    // MARK: 路由

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        lastActivity = Date()
        switch (request.method, request.path) {

        case ("GET", "/"), ("GET", "/index.html"):
            return .html(WebUI.page)

        case ("GET", "/favicon.ico"), ("GET", "/app-icon-ragdoll-v1.png"):
            guard let url = Bundle.main.url(forResource: "WebIcon", withExtension: "png") else {
                return .error("网页图标资源缺失", status: 500)
            }
            do { return .binary(try Data(contentsOf: url), type: "image/png") }
            catch { return .error(error.localizedDescription, status: 500) }

        case ("GET", "/api/state"):
            return .json(["device": UIDevice.current.name,
                          "totalBooks": books.books.count])

        // MARK: 书
        case ("GET", "/api/books"):
            return .json(["books": books.sortedBooks.map { book in
                [
                    "id": book.id.uuidString,
                    "title": book.title,
                    "author": book.author,
                    "format": book.format.label,
                    "chapters": book.chapterCount,
                    "progress": book.progressText
                ] as [String: Any]
            }])

        case ("POST", "/api/book/delete"):
            guard let id = request.uuid("id") else { return .error("参数不完整") }
            do { try books.delete(bookID: id) }
            catch { return .error(error.localizedDescription, status: 409) }
            note("网页删除了一本书")
            return .ok()

        case ("POST", "/api/book/upload"):
            guard let boundary = Multipart.boundary(from: request.contentType) else {
                return .error("请求格式不正确")
            }
            let body = request.body
            let parts: [MultipartPart]
            do {
                parts = try await Task.detached(priority: .userInitiated) {
                    try Multipart.parse(body: body, boundary: boundary)
                }.value
            } catch { return .error(error.localizedDescription) }

            var saved = 0
            var failure: String?
            for part in parts {
                guard let name = part.fileName, !part.data.isEmpty else { continue }
                do {
                    let book = try await books.importBook(data: part.data, fileName: name)
                    saved += 1
                    receivedCount += 1
                    note("收到《\(book.title)》，共 \(book.chapterCount) 章")
                } catch {
                    failure = error.localizedDescription
                }
            }
            if saved == 0 { return .error(failure ?? "没有可导入的文件") }
            return .ok(["saved": saved, "error": failure ?? ""])

        default:
            return .notFound
        }
    }

    private func note(_ text: String) {
        lastEvent = text
    }

}
