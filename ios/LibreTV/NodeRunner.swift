import Foundation
import CryptoKit
import NodeMobile

/// 在 App 进程内启动 nodejs-mobile，运行 LibreTV 的 Next.js 服务端（只监听 127.0.0.1）。
///
/// - App 包内是只读的，所以首次启动（或版本变化）时把 nodejs-project 复制到 Application Support 再运行；
/// - 访问密码与签名密钥在本机随机生成，只用于这台手机上的本地服务，网页端由 App 自动登录。
final class NodeRunner {
    static let shared = NodeRunner()

    static let port = 38080
    static let host = "127.0.0.1"
    static var baseURL: URL { URL(string: "http://\(host):\(port)/")! }

    private(set) var started = false
    private let defaults = UserDefaults.standard

    // MARK: - 本机凭证

    private func persistentRandom(_ key: String) -> String {
        if let v = defaults.string(forKey: key), !v.isEmpty { return v }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let v = bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(v, forKey: key)
        return v
    }

    var password: String { persistentRandom("ltv.local.password") }
    var secret: String { persistentRandom("ltv.local.secret") }

    /// 与 LibreTV src/lib/auth.ts 的 signSession() 相同：`<expiresAtMs>.<hex(hmacSHA256(secret, expiresAtMs))>`
    func makeSessionCookie() -> HTTPCookie? {
        let expires = Date().addingTimeInterval(89 * 24 * 3600)
        let payload = String(Int64(expires.timeIntervalSince1970 * 1000))
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        return HTTPCookie(properties: [
            .domain: NodeRunner.host,
            .path: "/",
            .name: "ltv_session",
            .value: "\(payload).\(hex)",
            .expires: expires,
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ])
    }

    // MARK: - 目录

    private var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var projectDir: URL { supportDir.appendingPathComponent("nodejs-project", isDirectory: true) }

    static var logDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 把包内的 nodejs-project 同步到可写目录。返回 true 表示做了复制（首次启动或升级）。
    @discardableResult
    func prepareProject() throws -> Bool {
        let fm = FileManager.default
        guard let bundled = Bundle.main.url(forResource: "nodejs-project", withExtension: nil) else {
            throw NSError(domain: "LibreTV", code: 1, userInfo: [NSLocalizedDescriptionKey: "安装包里缺少 nodejs-project"])
        }
        let stampName = ".bundle-id"
        let bundledStamp = (try? String(contentsOf: bundled.appendingPathComponent(stampName), encoding: .utf8)) ?? "unknown"
        let installedStamp = try? String(contentsOf: projectDir.appendingPathComponent(stampName), encoding: .utf8)
        if installedStamp == bundledStamp, fm.fileExists(atPath: projectDir.appendingPathComponent("main.js").path) {
            return false
        }
        let staging = supportDir.appendingPathComponent("nodejs-project.staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: bundled, to: staging)
        try? fm.removeItem(at: projectDir)
        try fm.moveItem(at: staging, to: projectDir)
        var url = projectDir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return true
    }

    // MARK: - 启动

    func start() {
        guard !started else { return }
        started = true

        redirectLogs()

        let env: [String: String] = [
            "PASSWORD": password,
            "PROXY_SECRET": secret,
            "PORT": String(NodeRunner.port),
            "HOSTNAME": NodeRunner.host,
            "NODE_ENV": "production",
            "NEXT_TELEMETRY_DISABLED": "1",
            "COOKIE_SECURE": "false",
            "TMPDIR": NSTemporaryDirectory(),
            "HOME": supportDir.path,
        ]
        for (k, v) in env { setenv(k, v, 1) }

        let script = projectDir.appendingPathComponent("main.js").path
        let args = ["node", "--jitless", script]

        let thread = Thread {
            NodeRunner.runNode(args)
        }
        thread.name = "nodejs"
        thread.stackSize = 16 * 1024 * 1024
        thread.start()
    }

    /// libuv 要求 argv 的各个字符串在一块连续内存里（与 nodejs-mobile 官方示例一致）。
    private static func runNode(_ args: [String]) {
        let cStrings = args.map { Array($0.utf8CString) }
        let total = cStrings.reduce(0) { $0 + $1.count }
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: total)
        var argv = [UnsafeMutablePointer<CChar>?]()
        var offset = 0
        for s in cStrings {
            let p = buffer + offset
            s.withUnsafeBufferPointer { src in
                p.initialize(from: src.baseAddress!, count: s.count)
            }
            argv.append(p)
            offset += s.count
        }
        argv.append(nil)
        let code = argv.withUnsafeMutableBufferPointer { ptr -> Int32 in
            node_start(Int32(args.count), ptr.baseAddress)
        }
        NSLog("[LibreTV] node exited with code %d", code)
        // node 只能启动一次；一旦退出就无法在同一进程内恢复
        NotificationCenter.default.post(name: .nodeDidExit, object: nil, userInfo: ["code": code])
    }

    private func redirectLogs() {
        let log = NodeRunner.logDir.appendingPathComponent("node.log")
        let prev = NodeRunner.logDir.appendingPathComponent("node.prev.log")
        let fm = FileManager.default
        try? fm.removeItem(at: prev)
        if fm.fileExists(atPath: log.path) { try? fm.moveItem(at: log, to: prev) }
        fm.createFile(atPath: log.path, contents: nil)
        freopen(log.path, "a+", stdout)
        freopen(log.path, "a+", stderr)
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
    }

    // MARK: - 健康检查

    func ping(timeout: TimeInterval = 2, completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: NodeRunner.baseURL.appendingPathComponent("api/status"))
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    /// 反复探测直到服务就绪或超时
    func waitUntilReady(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func attempt() {
            ping { ok in
                if ok { completion(true); return }
                if Date() > deadline { completion(false); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { attempt() }
            }
        }
        attempt()
    }
}

extension Notification.Name {
    static let nodeDidExit = Notification.Name("LibreTVNodeDidExit")
}
