import Foundation
import Network

/// 极简静态文件服务器：把 App Bundle 里的 Web/ 目录挂到 http://127.0.0.1:<port>
/// 目的：给 WKWebView 一个「正常来源」，否则 file:// 下 localStorage / IndexedDB
/// （笔记站把图片存在 IndexedDB）不可用，等于笔记功能废掉。
final class LocalServer {

    enum ServerError: Error { case cannotListen, noRoot }

    let port: UInt16
    private let root: URL
    private let queue = DispatchQueue(label: "biji.server", qos: .userInitiated)
    private var listener: NWListener?
    private let keepAlive: [String] = []

    /// root：资源目录；port 传 0 表示由系统分配空闲端口
    init(root: URL, port: UInt16 = 0) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { throw ServerError.noRoot }
        self.root = root
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
        self.listener = l
        self.port = 0
    }

    /// 启动监听；端口就绪后回调 assignedPort
    func start(onReady: @escaping (UInt16) -> Void) throws {
        guard let listener = listener else { throw ServerError.cannotListen }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let p = listener.port?.rawValue { onReady(p) }
            case .failed(let err):
                print("[biji] listener failed: \(err)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, !data.isEmpty else {
                conn.cancel(); return
            }
            let head = String(decoding: data, as: UTF8.self)
            let firstLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = firstLine.split(separator: " ")
            let rawPath = parts.count >= 2 ? String(parts[1]) : "/"
            let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            let rel = (path == "/" ? "/index.html" : path) as String
            let fileURL = self.root.appendingPathComponent(rel.hasPrefix("/") ? String(rel.dropFirst()) : rel)
            // 防目录穿越
            let resolved = fileURL.standardizedFileURL.path
            guard resolved.hasPrefix(self.root.standardizedFileURL.path) else {
                self.send(conn, status: "403 Forbidden", mime: "text/plain", body: Data("forbidden".utf8))
                return
            }
            guard let body = try? Data(contentsOf: fileURL) else {
                self.send(conn, status: "404 Not Found", mime: "text/plain", body: Data("not found".utf8))
                return
            }
            let mime = self.mime(for: resolved)
            self.send(conn, status: "200 OK", mime: mime, body: body)
        }
    }

    private func mime(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ttf": return "font/ttf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }

    private func send(_ conn: NWConnection, status: String, mime: String, body: Data) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(mime)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    deinit { listener?.cancel() }
}
