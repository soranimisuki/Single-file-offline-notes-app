import UIKit
import WebKit
import UniformTypeIdentifiers

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, WKScriptMessageHandler {

    var window: UIWindow?
    private var webView: WKWebView?
    private var server: LocalServer?
    private var launched = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        let w = UIWindow(frame: UIScreen.main.bounds)
        window = w

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(self, name: "biji")   // 页面导出/导入桥

        let web = WKWebView(frame: w.bounds, configuration: config)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView = web
        w.addSubview(web)
        w.makeKeyAndVisible()

        let webRoot = Bundle.main.resourceURL?.appendingPathComponent("Web")

        if let root = webRoot, let srv = try? LocalServer(root: root) {
            server = srv
            srv.start(onReady: { [weak self] port in
                guard let self = self, !self.launched else { return }
                self.launched = true
                if let u = URL(string: "http://127.0.0.1:\(port)/index.html") {
                    DispatchQueue.main.async { self.webView?.load(URLRequest(url: u)) }
                }
            })
            // 兜底：3 秒还没起来就直接读本地文件（图片功能会失效，但页面能用）
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self, !self.launched, let root = webRoot else { return }
                self.launched = true
                self.webView?.loadFileURL(root.appendingPathComponent("index.html"),
                                           allowingReadAccessTo: root)
            }
        } else if let root = webRoot {
            webView?.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        }

        return true
    }

    // MARK: - JS 桥

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "biji",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        if type == "export" {
            let name = (body["name"] as? String) ?? "笔记站备份.json"
            let text = (body["data"] as? String) ?? ""
            saveText(name: name, text: text)
        } else if type == "import" {
            presentImporter()
        }
    }

    private func saveText(name: String, text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let root = self.window?.rootViewController else { return }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = docs.appendingPathComponent(name)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let pop = share.popoverPresentationController {
                    pop.sourceView = self.window
                    pop.sourceRect = CGRect(x: (self.window?.bounds.midX) ?? 0,
                                            y: (self.window?.bounds.midY) ?? 0, width: 1, height: 1)
                }
                root.present(share, animated: true)
            } catch {
                let alert = UIAlertController(title: "保存失败", message: error.localizedDescription, preferredStyle: .alert)
                root.present(alert, animated: true)
            }
        }
    }

    private func presentImporter() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let root = self.window?.rootViewController else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText], asCopy: true)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            root.present(picker, animated: true)
        }
    }

    /// 回传给页面的 window.__bijiNativeImport(text)
    fileprivate func deliverImported(text: String) {
        let literal = Self.jsStringLiteral(text)
        let js = "(function(){ if(window.__bijiNativeImport){ window.__bijiNativeImport(\(literal)); } })()"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// 生成安全的 JS 字符串字面量（借 JSON 序列化自动转义）
    static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
              var arr = String(data: data, encoding: .utf8),
              arr.count >= 2 else {
            return "\"\""
        }
        arr.removeFirst()   // [
        arr.removeLast()    // ]
        return arr
    }
}

extension AppDelegate: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        var text = ""
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            text = s
        } else if let s = try? String(contentsOf: url, encoding: .isoLatin1) {
            text = s
        } else if let d = try? Data(contentsOf: url) {
            text = String(decoding: d, as: UTF8.self)
        }
        deliverImported(text: text)
    }
}
