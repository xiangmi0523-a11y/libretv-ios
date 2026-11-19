import UIKit
import WebKit
import AVFoundation

/// 主界面：启动内置服务 → 自动登录 → 用 WKWebView 打开 LibreTV。
final class WebViewController: UIViewController {
    private var webView: WKWebView!
    private let splash = SplashView()
    private let recoveringBanner = UILabel()
    private var pageBackground = UIColor(red: 0x0b / 255, green: 0x10 / 255, blue: 0x1a / 255, alpha: 1)
    private var pageIsDark = true
    private var hasLoadedOnce = false
    private var recovering = false
    private var downloads: [WKDownload: URL] = [:]

    override var preferredStatusBarStyle: UIStatusBarStyle { pageIsDark ? .lightContent : .darkContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = pageBackground
        setupWebView()
        setupSplash()
        setupBanner()

        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(nodeDidExit(_:)), name: .nodeDidExit, object: nil)

        bootstrap()
    }

    // MARK: - 启动流程

    private func bootstrap() {
        splash.setStatus("正在启动…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let copied = try NodeRunner.shared.prepareProject()
                if copied { DispatchQueue.main.async { self.splash.setStatus("首次启动，正在准备本地服务…") } }
                DispatchQueue.main.async {
                    NodeRunner.shared.start()
                    self.splash.setStatus("正在启动本地服务…")
                    NodeRunner.shared.waitUntilReady(timeout: 120) { ok in
                        if ok { self.loadApp() } else { self.splash.showError("本地服务启动超时。\n请完全关闭 App 后重新打开。\n日志在「文件」App →「我的 iPhone」→ LibreTV → logs。") }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.splash.showError("准备失败：\(error.localizedDescription)") }
            }
        }
    }

    private func loadApp() {
        if let testURL = TestHooks.pageURL {
            webView.load(URLRequest(url: testURL)); hasLoadedOnce = true; return
        }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        guard let cookie = NodeRunner.shared.makeSessionCookie() else {
            webView.load(URLRequest(url: NodeRunner.baseURL)); return
        }
        store.setCookie(cookie) { [weak self] in
            guard let self else { return }
            if self.hasLoadedOnce, self.webView.url != nil {
                self.webView.reload()
            } else {
                self.webView.load(URLRequest(url: NodeRunner.baseURL))
            }
            self.hasLoadedOnce = true
        }
    }

    // MARK: - 界面

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "Mobile/15E148 LibreTV-iOS"
        // 不开启「元素全屏」：iPhone 上 WKWebView 的元素全屏在横屏时会丢失视频画面（只剩声音）。
        // 关掉后播放器的全屏按钮走 iOS 原生视频全屏（video.webkitEnterFullscreen），
        // 横竖屏旋转、画中画、隔空播放都由系统播放器处理。
        if #available(iOS 16.4, *) {
            config.preferences.isElementFullscreenEnabled = TestHooks.elementFullscreen
        }
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let controller = config.userContentController
        controller.add(WeakScriptHandler(self), name: "ltvTheme")
        controller.addUserScript(WKUserScript(source: WebViewController.themeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = pageBackground
        webView.scrollView.backgroundColor = pageBackground
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        let refresh = UIRefreshControl()
        refresh.tintColor = .lightGray
        refresh.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupSplash() {
        splash.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splash)
        NSLayoutConstraint.activate([
            splash.topAnchor.constraint(equalTo: view.topAnchor),
            splash.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splash.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splash.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        splash.onRetry = { [weak self] in self?.retryAfterError() }
    }

    private func setupBanner() {
        recoveringBanner.text = "  正在恢复本地服务…  "
        recoveringBanner.font = .systemFont(ofSize: 13, weight: .medium)
        recoveringBanner.textColor = .white
        recoveringBanner.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        recoveringBanner.layer.cornerRadius = 14
        recoveringBanner.clipsToBounds = true
        recoveringBanner.isHidden = true
        recoveringBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recoveringBanner)
        NSLayoutConstraint.activate([
            recoveringBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recoveringBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            recoveringBanner.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func hideSplash() {
        guard splash.superview != nil, splash.alpha > 0 else { return }
        UIView.animate(withDuration: 0.25, animations: { self.splash.alpha = 0 }) { _ in self.splash.isHidden = true }
    }

    private func retryAfterError() {
        splash.resetToLoading()
        NodeRunner.shared.waitUntilReady(timeout: 30) { ok in
            if ok { self.loadApp() } else { self.splash.showError("本地服务没有响应。\n请从后台划掉 App 再重新打开。") }
        }
    }

    @objc private func pullToRefresh(_ sender: UIRefreshControl) {
        NodeRunner.shared.waitUntilReady(timeout: 10) { _ in
            self.webView.reload()
            sender.endRefreshing()
        }
    }

    // MARK: - 前后台

    @objc private func appDidBecomeActive() {
        guard hasLoadedOnce, !recovering else { return }
        NodeRunner.shared.ping { ok in
            if ok { return }
            // 挂起期间监听 socket 可能被系统回收，node 侧看门狗会重新 listen；这里等它恢复
            self.recovering = true
            self.recoveringBanner.isHidden = false
            NodeRunner.shared.waitUntilReady(timeout: 30) { ok in
                self.recovering = false
                self.recoveringBanner.isHidden = true
                if ok {
                    if self.webView.url == nil || self.webView.isLoading == false && self.lastLoadFailed { self.loadApp() }
                } else {
                    self.splash.isHidden = false
                    self.splash.alpha = 1
                    self.splash.showError("本地服务没有响应。\n请从后台划掉 App 再重新打开。")
                }
            }
        }
    }

    private var lastLoadFailed = false

    @objc private func nodeDidExit(_ note: Notification) {
        DispatchQueue.main.async {
            self.splash.isHidden = false
            self.splash.alpha = 1
            self.splash.showError("本地服务已停止。\n请从后台划掉 App 再重新打开。", retry: false)
        }
    }

    // MARK: - 主题同步（状态栏颜色跟随网页亮/暗主题）

    fileprivate func applyTheme(dark: Bool, background: String?) {
        pageIsDark = dark
        if let bg = background, let color = UIColor(cssRGB: bg) { pageBackground = color }
        view.backgroundColor = pageBackground
        webView.backgroundColor = pageBackground
        webView.scrollView.backgroundColor = pageBackground
        setNeedsStatusBarAppearanceUpdate()
    }

    private static let themeScript = """
    (function(){
      function post(){
        try{
          var d=document.documentElement.classList.contains('dark');
          var bg=getComputedStyle(document.body||document.documentElement).backgroundColor;
          window.webkit.messageHandlers.ltvTheme.postMessage({dark:d,bg:bg});
        }catch(e){}
      }
      post();
      new MutationObserver(post).observe(document.documentElement,{attributes:true,attributeFilter:['class']});
    })();
    """

    // MARK: - 下载

    fileprivate func presentShare(for url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        topPresenter().present(vc, animated: true)
    }

    fileprivate func topPresenter() -> UIViewController {
        var vc: UIViewController = self
        while let p = vc.presentedViewController { vc = p }
        return vc
    }

    /// 仅供 CI 模拟器测试（scripts/fullscreen-test.sh）：起播后进全屏，再转横屏
    private func runFullscreenTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            self.webView.evaluateJavaScript("window.ltvTestEnterFullscreen && window.ltvTestEnterFullscreen()") { _, error in
                if let error { NSLog("[ltv-test] enter fullscreen: \(error)") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let scene = self?.view.window?.windowScene else { return }
                if #available(iOS 16.0, *) {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                        NSLog("[ltv-test] rotate: \(error)")
                    }
                }
            }
        }
    }

    private static func isLocal(_ url: URL) -> Bool {
        (url.host == NodeRunner.host || url.host == "localhost") && (url.port ?? 80) == NodeRunner.port
    }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { decisionHandler(.download); return }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { decisionHandler(.allow); return }

        if ["blob", "data", "about", "javascript"].contains(scheme) { decisionHandler(.allow); return }
        if WebViewController.isLocal(url) || TestHooks.isTestURL(url) { decisionHandler(.allow); return }

        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if scheme == "http" || scheme == "https" {
            if isMainFrame {
                // 站外链接（项目主页、文档等）交给 Safari，App 内只跑本地服务
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
            return
        }
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse,
           let disp = http.value(forHTTPHeaderField: "Content-Disposition"),
           disp.lowercased().contains("attachment") {
            decisionHandler(.download); return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastLoadFailed = false
        if webView.url.map(WebViewController.isLocal) == true { hideSplash() }
        if let url = webView.url, TestHooks.isTestURL(url) {
            hideSplash()
            if TestHooks.fullscreenTest { runFullscreenTest() }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    private func handleLoadError(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return } // 转为下载时的“帧加载中断”
        lastLoadFailed = true
        NodeRunner.shared.waitUntilReady(timeout: 30) { ok in
            if ok { self.loadApp() }
            else if !self.hasLoadedOnce || self.splash.alpha > 0 {
                self.splash.showError("页面加载失败：\(ns.localizedDescription)")
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if WebViewController.isLocal(url) || url.scheme == "blob" {
                webView.load(navigationAction.request)
            } else {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        topPresenter().present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        topPresenter().present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        topPresenter().present(a, animated: true)
    }
}

// MARK: - WKDownloadDelegate

extension WebViewController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = suggestedFilename.isEmpty ? "download" : suggestedFilename.replacingOccurrences(of: "/", with: "_")
        var target = dir.appendingPathComponent(safeName)
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        var i = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            i += 1
        }
        downloads[download] = target
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloads.removeValue(forKey: download) else { return }
        presentShare(for: url)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: download)
        let a = UIAlertController(title: "下载失败", message: error.localizedDescription, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        topPresenter().present(a, animated: true)
    }
}

// MARK: - 脚本消息

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebViewController?
    init(_ target: WebViewController) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ltvTheme", let body = message.body as? [String: Any] else { return }
        target?.applyTheme(dark: (body["dark"] as? Bool) ?? true, background: body["bg"] as? String)
    }
}

extension UIColor {
    /// 解析 getComputedStyle 返回的 "rgb(r, g, b)" / "rgba(r, g, b, a)"
    convenience init?(cssRGB: String) {
        let nums = cssRGB
            .replacingOccurrences(of: "rgba", with: "")
            .replacingOccurrences(of: "rgb", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "() "))
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count >= 3 else { return nil }
        if nums.count >= 4, nums[3] == 0 { return nil } // 透明背景不采用
        self.init(red: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, alpha: 1)
    }
}
