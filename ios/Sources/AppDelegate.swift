import UIKit
import WebKit
import UniformTypeIdentifiers

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var webView: WKWebView?
    private var server: LocalServer?
    private var pendingImportName: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        let w = UIWindow(frame: UIScreen.main.bounds)
        window = w

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // 允许页面用 localStorage / IndexedDB（file:// 场景下 WKWebView 默认不给）
        if let prefs = config.preferences as AnyObject as? WKPreferences {
            prefs.setValue(true, forKey: "allowFileAccessFromFileURLs")
        }
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let web = WKWebView(frame: w.bounds, configuration: config)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView = web
        w.addSubview(web)
        w.makeKeyAndVisible()

        // 内置资源根目录：Bundle/Web（xcodegen 以 folder 方式拷入）
        let webRoot = Bundle.main.resourceURL?.appendingPathComponent("Web")

        if let root = webRoot, let srv = try? LocalServer(root: root, port: 0) {
            server = srv
            var launched = false
            do {
                try srv.start(onReady: { [weak self] port in
                    guard let self = self, !launched else { return }
                    launched = true
                    if let u = URL(string: "http://127.0.0.1:\(port)/index.html") {
                        DispatchQueue.main.async { self.webView?.load(URLRequest(url: u)) }
                    }
                })
            } catch {
                print("[biji] server start failed: \(error)")
            }
            // 兜底：3 秒还没起来就直接读本地文件（图片功能会失效，但页面能用）
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self, !launched, let root = webRoot else { return }
                launched = true
                self.webView?.loadFileURL(root.appendingPathComponent("index.html"),
                                           allowingReadAccessTo: root)
            }
        } else {
            // 极简兜底：bundle 里找 index.html
            if let root = webRoot {
                webView?.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
            }
        }

        return true
    }

    // MARK: - JS 桥（导出 / 导入）

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
                share.popoverPresentationController?.sourceView = self.window
                share.popoverPresentationController?.sourceRect = CGRect(x: self.window!.bounds.midX, y: self.window!.bounds.midY, width: 1, height: 1)
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
            let types: [UTType] = [.json, .text]
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            root.present(picker, animated: true)
        }
    }

    private func sendToJS(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// 把读到的文件内容回传给页面的 window.__bijiNativeImport(text)
    fileprivate func deliverImported(text: String) {
        let encoded = Self.jsStringLiteral(text)
        sendToJS("(function(){ if(window.__bijiNativeImport){ window.__bijiNativeImport(\(encoded)); } })()")
    }

    /// 生成一个安全的 JS 字符串字面量（含转义，避免引号/换行/</script> 注入）
    static func jsStringLiteral(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        guard var arr = String(data: data ?? Data("[]".utf8), encoding: .utf8), arr.count >= 2 else {
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
        }
        deliverImported(text: text)
    }
}
