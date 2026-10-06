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
    /// `<input type=file>` 的完成回调（WKUIDelegate 给的，不能丢）
    private var openPanelCompletion: (([URL]?) -> Void)?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)

        // 关键：必须有 rootViewController —— 导入/导出的系统选择器、分享面板都要通过
        // view controller 呈现。之前直接把 WKWebView addSubview 到 window 上导致
        // window.rootViewController == nil，present 被静默跳过 → 点「导入」毫无反应。
        let root = UIViewController()
        root.view.backgroundColor = UIColor(red: 0.902, green: 0.882, blue: 0.835, alpha: 1)  // 砂岩底色
        w.rootViewController = root
        window = w
        w.makeKeyAndVisible()

        // 诊断层：出错时把原因显示在屏幕上，而不是白屏/静默退出
        diag.numberOfLines = 0
        diag.textAlignment = .center
        diag.font = .systemFont(ofSize: 13)
        diag.textColor = UIColor(white: 0.12, alpha: 1)
        diag.backgroundColor = UIColor(white: 1, alpha: 0.94)
        diag.isHidden = true
        root.view.addSubview(diag)
        layoutDiag()

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

        let web = WKWebView(frame: root.view.bounds, configuration: config)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.navigationDelegate = self
        web.uiDelegate = self          // 关键：没有它 <select> / <input type=file> / confirm() 全部无反应
        webView = web
        root.view.addSubview(web)

        // 优先走内置 localhost 服务器：file:// 下 IndexedDB 不可用，图片会丢
        if let srv = try? LocalServer(root: webRoot) {
            srv.importProvider = { [weak self] in self?.readStagedImport() }
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
        layoutDiag()
        diag.isHidden = false
    }

    private func layoutDiag() {
        let b = window?.bounds ?? .zero
        diag.frame = CGRect(x: 24, y: 120, width: max(0, b.width - 48), height: max(0, b.height - 240))
    }

    /// 弹系统面板的统一入口：一定要有 presenter，否则静默失败
    @discardableResult
    private func presentSheet(_ vc: UIViewController, tag: String) -> Bool {
        guard let host = window?.rootViewController else {
            note("无法弹出\(tag)：窗口没有 rootViewController")
            return false
        }
        // 上一个弹窗还在（比如 confirm 之后又来文件选择器）时，先等它关掉再弹，
        // 否则 UIKit 会报 "already presenting" 并静默失败。
        if host.presentedViewController != nil {
            host.dismiss(animated: true) { [weak self] in
                _ = self?.presentSheet(vc, tag: tag)
            }
            return true
        }
        if vc.popoverPresentationController != nil {
            vc.popoverPresentationController?.sourceView = host.view
            vc.popoverPresentationController?.sourceRect = CGRect(
                x: (host.view.bounds.midX), y: (host.view.bounds.midY), width: 1, height: 1)
        }
        host.present(vc, animated: true)
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
            guard let self = self else { return }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = docs.appendingPathComponent(name)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.presentSheet(UIActivityViewController(activityItems: [url], applicationActivities: nil),
                                  tag: "导出分享面板")
            } catch {
                self.showAlert("保存失败", error.localizedDescription)
            }
        }
    }

    private func presentImporter() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText], asCopy: true)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            self.presentSheet(picker, tag: "导入文件选择器")
        }
    }

    /// 回传导入内容。数据可能很大（含图片 base64），**不走 evaluateJavaScript 传字符串**，
    /// 而是先写到 App 沙盒，再让页面自己 fetch 取——避免超长 JS 字符串被截断或失败。
    fileprivate func deliverImported(text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("biji-import.json")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                print("[biji] import staged: \(text.count) chars")
            } catch {
                self.showAlert("读取失败", error.localizedDescription)
                return
            }
            let js = "(function(){ if(window.__bijiNativeImport){ window.__bijiNativeImport('file'); } })()"
            self.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// App 内的文件接口由页面调用（通过本地服务器的 /biji-import.json 路由读取，读一次即清）
    func readStagedImport() -> Data? {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("biji-import.json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)   // 读一次即清，避免下次误用旧数据
        return d
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

// MARK: - WKUIDelegate：下拉框 / 文件选择 / JS 对话框
//
// 缺这一段会导致三类功能「点了没反应」：
//   1. HTML <select> 下拉（识别后端、API 格式、分区…）——iOS 15+ 由 UIDelegate 弹原生控件
//   2. <input type="file"> 点击
//   3. JS 的 alert() / confirm() / prompt()——WKWebView 默认拦截，导入流程里的
//      confirm() 会静默卡死（页面在等返回值，永远等不到）
extension SceneDelegate: WKUIDelegate {

    /// <select> 等原生弹出控件需要有人承载；返回 nil 表示交给 WebKit 默认处理
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    /// JS alert()
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: "笔记站", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        presentSheet(alert, tag: "提示框")
    }

    /// JS confirm()——导入流程靠它问「合并还是覆盖」，必须实现
    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: "请确认", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        presentSheet(alert, tag: "确认框")
    }

    /// JS prompt()
    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: "请输入", message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        presentSheet(alert, tag: "输入框")
    }

    /// HTML <input type="file">：把系统选择器接上（页面里图片上传、导入兜底都靠它）
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let picker: UIDocumentPickerViewController
        if parameters.allowsMultipleSelection {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            picker.allowsMultipleSelection = true
        } else {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            picker.allowsMultipleSelection = false
        }
        openPanelCompletion = completionHandler
        presentSheet(picker, tag: "文件选择器")
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
        // `<input type=file>` 的回调：原生桥的导入走下面的 didPickImport 分支
        if let cb = openPanelCompletion {
            openPanelCompletion = nil
            cb(urls)
            return
        }
        guard let url = urls.first else { return }
        var text = ""
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            text = s
        } else if let d = try? Data(contentsOf: url) {
            text = String(decoding: d, as: UTF8.self)
        }
        deliverImported(text: text)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let cb = openPanelCompletion {
            openPanelCompletion = nil
            cb(nil)
        }
    }
}
