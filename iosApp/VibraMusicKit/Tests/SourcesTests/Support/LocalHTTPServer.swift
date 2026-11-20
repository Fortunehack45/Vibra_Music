import Foundation
import Network

/// A tiny in-process HTTP/1.1 server on 127.0.0.1, for tests where the *player's* HTTP stack must
/// fetch (AVFoundation doesn't go through `URLProtocol`). Serves fixed bodies by path, honours a
/// single `Range: bytes=a-b`, closes after each response, and records the paths asked for.
final class LocalHTTPServer: @unchecked Sendable {
    struct File {
        var body: Data
        var contentType: String
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var served: [String] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func serve(_ path: String, _ body: Data, contentType: String) {
        lock.withLock { files[path] = File(body: body, contentType: contentType) }
    }

    var requestedPaths: [String] { lock.withLock { served } }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = LockedFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    if once.set() { continuation.resume() }
                case .failed(let error):
                    if once.set() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaders(connection, buffer: Data())
    }

    private func receiveHeaders(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receiveHeaders(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.count > 1 ? String(parts[1]).components(separatedBy: "?")[0] : "/"
        let range = lines.first { $0.lowercased().hasPrefix("range:") }
            .flatMap { $0.split(separator: "=").last }
            .map { $0.split(separator: "-", omittingEmptySubsequences: false).map { Int64($0.trimmingCharacters(in: .whitespaces)) } }
        let file = lock.withLock { () -> File? in
            served.append(path)
            return files[path]
        }
        var header: String
        var body = Data()
        if let file {
            let total = Int64(file.body.count)
            if let range, range.count == 2, let start = range[0] {
                let end = min(range[1] ?? (total - 1), total - 1)
                body = file.body.subdata(in: Int(start)..<Int(end + 1))
                header = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(end)/\(total)\r\n"
            } else {
                body = file.body
                header = "HTTP/1.1 200 OK\r\n"
            }
            header += "Content-Type: \(file.contentType)\r\nAccept-Ranges: bytes\r\n"
        } else {
            header = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n"
        }
        header += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        if method != "HEAD" { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// True the first time only.
    func set() -> Bool {
        lock.withLock {
            defer { value = true }
            return !value
        }
    }
}
