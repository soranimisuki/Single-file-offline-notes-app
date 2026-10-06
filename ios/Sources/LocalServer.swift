import Foundation
import Network

/// 极简静态文件服务器：把 App Bundle 里的 Web/ 目录挂到 http://127.0.0.1:<随机端口>
/// 目的：给 WKWebView 一个「正常来源」。WKWebView 在 file:// 下 IndexedDB 不可用，
/// 而笔记站的图片存在 IndexedDB —— 直接 loadFileURL 会导致图片功能失效。
final class LocalServer {

    enum ServerError: Error { case noRoot }

    private let root: URL
    private let queue = DispatchQueue(label: "biji.server", qos: .userInitiated)
    private var listener: NWListener?
    private var ready = false

    init(root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { throw ServerError.noRoot }
        self.root = root.standardizedFileURL
        self.listener = try NWListener(using: .tcp, on: NWEndpoint.Port.any)
    }

    /// 监听就绪后回调实际端口
    func start(onReady: @escaping (UInt16) -> Void) {
        guard let listener = listener else { return }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if !self.ready, let p = listener.port?.rawValue {
                    self.ready = true
                    onReady(p)
                }
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
        conn.receive(minimumIncompleteLength: 2, maximumLength: 262144) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, !data.isEmpty else {
                conn.cancel()
                return
            }
            let head = String(decoding: data, as: UTF8.self)
            let firstLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = firstLine.split(separator: " ")
            let rawPath = parts.count >= 2 ? String(parts[1]) : "/"
            let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            let rel = (path == "/") ? "/index.html" : path
            let name = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel

            let fileURL = self.root.appendingPathComponent(name).standardizedFileURL
            guard fileURL.path.hasPrefix(self.root.path) else {
                self.send(conn, status: "403 Forbidden", mime: "text/plain", body: Data("forbidden".utf8))
                return
            }
            guard let body = try? Data(contentsOf: fileURL) else {
                self.send(conn, status: "404 Not Found", mime: "text/plain", body: Data("not found".utf8))
                return
            }
            self.send(conn, status: "200 OK", mime: self.mime(for: fileURL.path), body: body)
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
