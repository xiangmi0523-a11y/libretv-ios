import Foundation

/// 只给 CI 里的模拟器测试用的开关，通过启动参数传入（`-LTVTestURL http://127.0.0.1:8099/...`）。
/// 正常从桌面打开 App 时这些参数都不存在，行为不受影响；测试页面也只允许本机地址。
enum TestHooks {
    private static let defaults = UserDefaults.standard

    /// 打开指定的本机测试页，而不是 LibreTV
    static var pageURL: URL? {
        guard let s = defaults.string(forKey: "LTVTestURL"), let url = URL(string: s), isTestURL(url) else { return nil }
        return url
    }

    /// 测试页加载后自动进全屏并转横屏
    static var fullscreenTest: Bool { defaults.bool(forKey: "LTVTestFullscreen") }

    /// 用于复现旧行为：开启 WKWebView 的元素全屏（正式使用时关闭）
    static var elementFullscreen: Bool { defaults.bool(forKey: "LTVTestElementFullscreen") }

    static func isTestURL(_ url: URL) -> Bool {
        guard defaults.string(forKey: "LTVTestURL") != nil else { return false }
        guard url.scheme == "http", url.host == "127.0.0.1" || url.host == "localhost" else { return false }
        return url.port != NodeRunner.port
    }
}
