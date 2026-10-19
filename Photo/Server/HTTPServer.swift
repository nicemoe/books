import Foundation
import Network

/// 极简 HTTP/1.1 服务端（基于 Network.framework，无第三方依赖）
final class HTTPServer: @unchecked Sendable {

    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    enum ServerError: LocalizedError {
        case noAvailablePort
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noAvailablePort: return "没有可用端口，请稍后重试"
            case .timedOut:        return "服务启动超时。请在「设置 → 隐私与安全性 → 本地网络」里允许本 App 访问局域网。"
            case .failed(let m):   return m
            }
        }
    }

    // 监听器、连接和启动过程统一由同一串行队列管理。
    private let queue = DispatchQueue(label: "reader.http.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    @discardableResult
    func start(handler: @escaping Handler) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        // 由系统分配空闲端口，不在失败后轮流重试不同端口。
        let candidate = try NWListener(using: params, on: .any)
        candidate.service = NWListener.Service(name: UIDeviceName.current, type: "_http._tcp")
        queue.sync {
            stopOnQueue()
            listener = candidate
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard listener === candidate else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let resumed = ResumeGuard()
                let timeout = DispatchWorkItem { [weak self, weak candidate] in
                    guard resumed.claim() else { return }
                    guard let candidate else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if self?.listener === candidate { self?.stopOnQueue() }
                    continuation.resume(throwing: ServerError.timedOut)
                }
                candidate.newConnectionHandler = { [weak self, weak candidate] connection in
                    guard let self, let candidate, self.listener === candidate else {
                        connection.cancel()
                        return
                    }
                    let wrapper = HTTPConnection(connection: connection, queue: self.queue, handler: handler) { [weak self] id in
                        self?.connections.removeValue(forKey: id)
                    }
                    self.connections[ObjectIdentifier(wrapper)] = wrapper
                    wrapper.start()
                }
                candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                    guard let candidate else { return }
                    switch state {
                    case .ready:
                        guard resumed.claim() else { return }
                        timeout.cancel()
                        guard self?.listener === candidate, let port = candidate.port else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        continuation.resume(returning: port.rawValue)
                    case .failed(let error):
                        if self?.listener === candidate { self?.stopOnQueue() }
                        if resumed.claim() {
                            timeout.cancel()
                            continuation.resume(throwing: ServerError.failed(error.localizedDescription))
                        }
                    case .cancelled:
                        if resumed.claim() {
                            timeout.cancel()
                            continuation.resume(throwing: CancellationError())
                        }
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + 10, execute: timeout)
                candidate.start(queue: queue)
            }
        }
    }

    func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        let all = Array(connections.values)
        connections.removeAll()
        all.forEach { $0.close() }
    }

    var hasActiveConnections: Bool { queue.sync { !connections.isEmpty } }
}

/// 保证 continuation 只被 resume 一次
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

// MARK: - 单条连接

private final class HTTPConnection {

    /// 单次请求体上限。请求体是整份读进内存再解析的，设太大在真机上会被系统回收；
    /// 网页端已经按 20MB 一批切分上传，64MB 留足余量。
    private static let maxBodyBytes = 64 * 1024 * 1024

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private let onClose: (ObjectIdentifier) -> Void

    /// 已读到 header、正在等 body 的请求
    private struct PendingRequest {
        var method: String
        var target: String
        var headers: [String: String]
        var contentLength: Int
        var keepAlive: Bool
    }

    private var buffer = Data()
    private var pending: PendingRequest?
    private var headerScanOffset = 0
    private var isHandling = false
    private var isClosed = false

    init(connection: NWConnection,
         queue: DispatchQueue,
         handler: @escaping HTTPServer.Handler,
         onClose: @escaping (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 17) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.buffer.count > Self.maxBodyBytes {
                    self.send(.text("413 Payload Too Large", status: 413), keepAlive: false)
                    return
                }
                self.drain()
            }

            if error != nil { self.close(); return }
            if isComplete { self.close(); return }
            if !self.isClosed { self.receive() }
        }
    }

    /// 从缓冲区里尽可能解析出完整请求。
    /// header 与 body 分两个阶段，body 阶段只比长度不再全量扫描，避免大文件上传时退化成 O(n²)。
    private func drain() {
        guard !isHandling, !isClosed else { return }

        if pending == nil {
            guard parseHeaders() else { return }
        }
        guard let request = pending, buffer.count >= request.contentLength else { return }

        // prefix / removeFirst 都是按元素个数算的，与 startIndex 无关，这里是安全的
        let body = Data(buffer.prefix(request.contentLength))
        buffer.removeFirst(request.contentLength)
        pending = nil

        // 一个请求处理完、缓冲区正好空了就重建一份，让 startIndex 回到 0，
        // 避免长连接上偏移量一路累加
        if buffer.isEmpty { buffer = Data() }

        dispatch(request, body: body)
    }

    /// 解析出 header 后把它从缓冲区里摘掉，返回是否成功
    private func parseHeaders() -> Bool {
        let terminator = Data("\r\n\r\n".utf8)

        // 关键：Data.removeSubrange 不会把 startIndex 归零，只是往前推。
        // 所以 keep-alive 连接处理完第一个请求后 startIndex 就不是 0 了，
        // count 和 endIndex 属于两个坐标系，混用会让 range(of:in:) 越界
        // 抛 NSRangeException（Swift 接不住，直接 abort）。
        // headerScanOffset 一律当作相对 startIndex 的偏移量，用 index(_:offsetBy:) 换算。
        let skip = min(max(0, headerScanOffset - 3), buffer.count)
        let searchStart = buffer.index(buffer.startIndex, offsetBy: skip)

        guard let range = buffer.range(of: terminator, in: searchStart..<buffer.endIndex) else {
            if buffer.count > 16 * 1024 {
                send(.text("Request headers too large", status: 400), keepAlive: false)
                return false
            }
            headerScanOffset = buffer.count
            return false
        }

        guard buffer.distance(from: buffer.startIndex, to: range.upperBound) <= 16 * 1024 else {
            send(.text("Request headers too large", status: 400), keepAlive: false)
            return false
        }
        let headText = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        headerScanOffset = 0

        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { close(); return false }

        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { close(); return false }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard headers[key] == nil else {
                send(.text("Duplicate header", status: 400), keepAlive: false)
                return false
            }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        guard headers["transfer-encoding"] == nil else {
            send(.text("Unsupported Transfer-Encoding", status: 400), keepAlive: false)
            return false
        }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let length = Int(rawLength) else {
            send(.text("Invalid Content-Length", status: 400), keepAlive: false)
            return false
        }
        guard length <= Self.maxBodyBytes else {
            send(.text("413 Payload Too Large", status: 413), keepAlive: false)
            return false
        }

        pending = PendingRequest(
            method: String(requestLine[0]).uppercased(),
            target: String(requestLine[1]),
            headers: headers,
            contentLength: length,
            keepAlive: headers["connection"]?.lowercased() != "close"
        )
        return true
    }

    private func dispatch(_ pending: PendingRequest, body: Data) {
        // 拆 path / query
        let target = pending.target
        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<mark])
            for pair in target[target.index(after: mark)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1
                    ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1]))
                    : ""
                query[key] = value
            }
        }
        path = path.removingPercentEncoding ?? path

        let request = HTTPRequest(method: pending.method,
                                  path: path,
                                  query: query,
                                  headers: pending.headers,
                                  body: body)
        let keepAlive = pending.keepAlive
        let handler = self.handler
        let queue = self.queue

        isHandling = true
        Task { [weak self] in
            let response = await handler(request)
            queue.async { self?.send(response, keepAlive: keepAlive) }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        guard !isClosed else { return }
        let data = response.serialized(keepAlive: keepAlive)
        isHandling = true
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else { self.close(); return }
            self.isHandling = false
            if keepAlive {
                self.drain()
            } else {
                self.close()
            }
        })
    }

    /// 可能从主线程（stop()）调用，所以统一回到连接自己的队列上执行，
    /// 避免和正在解析缓冲区的 receive/drain 抢同一份状态。
    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            buffer.removeAll()
            pending = nil
            connection.cancel()
            onClose(ObjectIdentifier(self))
        }
    }
}

// MARK: - 设备名（用于 Bonjour 广播）

enum UIDeviceName {
    static var current: String {
        let raw = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
        return raw.isEmpty ? "Photo" : "Photo (\(raw))"
    }
}
