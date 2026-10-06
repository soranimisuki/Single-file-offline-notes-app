import UIKit
import WebKit
import UniformTypeIdentifiers

/// App 入口：只负责提供 scene 配置，具体加载逻辑交给 SceneDelegate。
/// iPadOS 26 走 Scene 生命周期——缺 UIApplicationSceneManifest 会在启动时断言崩溃
/// （崩溃栈：-[UIApplication _runWithMainScene:] → NSAssertionHandler）。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let cfg = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        cfg.delegateClass = SceneDelegate.self
        return cfg
    }
}

/// 真正的界面所在：WKWebView + 内置 localhost 服务器 + 导出/导入桥
final class SceneDelegate: UIResponder, UIWindowSceneDelegate, WKScriptMessageHandler {

    var window: UIWindow?
    private var webView: WKWebView?
    private var server: LocalServer?
    private var loaded = false
    private let diag = UILabel()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.backgroundColor = UIColor(red: 0.902, green: 0.882, blue: 0.835, alpha: 1)   // 砂岩底色
        window = w

        // 诊断层：出错时把原因显示在屏幕上，而不是白屏/静默退出
        diag.numberOfLines = 0
        diag.textAlignment = .center
        diag.font = .systemFont(ofSize: 13)
        diag.textColor = UIColor(white: 0.12, alpha: 1)
        diag.backgroundColor = UIColor(white: 1, alpha: 0.94)
        diag.isHidden = true
        w.addSubview(diag)
        w.makeKeyAndVisible()

        // 内置资源检查
        guard let webRoot = Bundle.main.resourceURL?.appendingPathComponent("Web"),
              FileManager.default.fileExists(atPath: webRoot.appendingPathComponent("index.html").path) else {
            note("内置页面缺失：App 包里找不到 Web/index.html")
            return
        }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(self, name: "biji")

        let web = WKWebView(frame: w.bounds, configuration: config)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.navigationDelegate = self
        webView = web
        w.addSubview(web)

        // 优先走内置 localhost 服务器：file:// 下 IndexedDB 不可用，图片会丢
        if let srv = try? LocalServer(root: webRoot) {
            server = srv
            srv.start(onReady: { [weak self] port in
                guard let self = self, !self.loaded else { return }
                self.loaded = true
                if let u = URL(string: "http://127.0.0.1:\(port)/index.html") {
                    DispatchQueue.main.async { self.webView?.load(URLRequest(url: u)) }
                }
            })
        } else {
            note("localhost 服务器未启动，改用本地文件打开（图片功能会失效）")
        }

        // 兜底：3.5 秒还没加载成功就直接读文件
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self = self, !self.loaded else { return }
            self.loaded = true
            self.webView?.loadFileURL(webRoot.appendingPathComponent("index.html"),
                                      allowingReadAccessTo: webRoot)
        }
    }

    private func note(_ s: String) {
        print("[biji] " + s)
        diag.text = s
        diag.frame = (window?.bounds ?? .zero).insetBy(dx: 24, dy: 120)
        diag.isHidden = false
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
                if let pop = share.popoverPresentationController {
                    pop.sourceView = self.window
                    pop.sourceRect = CGRect(x: (self.window?.bounds.midX) ?? 0,
                                            y: (self.window?.bounds.midY) ?? 0, width: 1, height: 1)
                }
                root.present(share, animated: true)
            } catch {
                self.showAlert("保存失败", error.localizedDescription)
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
        let js = "(function(){ if(window.__bijiNativeImport){ window.__bijiNativeImport(\(Self.jsStringLiteral(text))); } })()"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// 借 JSON 序列化生成安全的 JS 字符串字面量（自动转义引号/换行）
    static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
              var arr = String(data: data, encoding: .utf8), arr.count >= 2 else {
            return "\"\""
        }
        arr.removeFirst()   // [
        arr.removeLast()    // ]
        return arr
    }

    private func showAlert(_ title: String, _ msg: String) {
        guard let root = window?.rootViewController else { return }
        root.present(UIAlertController(title: title, message: msg, preferredStyle: .alert), animated: true)
    }
}

// MARK: - 加载诊断

extension SceneDelegate: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[biji] loaded: " + (webView.url?.absoluteString ?? "?"))
        diag.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        note("页面加载失败：" + error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        note("页面无法打开：" + error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        note("网页进程被系统回收，正在重试…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, let u = self.webView?.url else { return }
            self.webView?.load(URLRequest(url: u))
        }
    }
}

extension SceneDelegate: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        var text = ""
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            text = s
        } else if let d = try? Data(contentsOf: url) {
            text = String(decoding: d, as: UTF8.self)
        }
        deliverImported(text: text)
    }
}
