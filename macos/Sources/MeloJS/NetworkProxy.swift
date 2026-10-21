import Foundation
import CFNetwork
import MeloCore

/// 已解析的 HTTP/HTTPS 代理配置（无效配置不会被创建）。
struct ResolvedHTTPProxy: Sendable, Equatable {
    let host: String
    let port: Int
    let username: String
    let password: String

    init?(_ settings: ProxySettings) {
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.enabled, !host.isEmpty, settings.port > 0, settings.port <= 65535 else {
            return nil
        }
        self.host = host
        self.port = settings.port
        self.username = settings.username
        self.password = settings.password
    }

    /// `Proxy-Authorization: Basic ...`（用户名/密码都为空时返回 nil）
    var basicAuthorization: String? {
        guard !username.isEmpty || !password.isEmpty else { return nil }
        let credential = "\(username):\(password)"
        return "Basic " + Data(credential.utf8).base64EncodedString()
    }
}

/// 线程安全的全局代理快照：@MainActor 上配置，NWHTTPClient 后台队列按请求读取。
final class NetworkProxyStore: @unchecked Sendable {
    static let shared = NetworkProxyStore()

    private let lock = NSLock()
    private var resolved: ResolvedHTTPProxy?

    private init() {}

    var current: ResolvedHTTPProxy? {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    /// 更新配置；无效配置（host 空/port 0/越界）视为禁用，返回 nil。
    @discardableResult
    func update(_ settings: ProxySettings) -> ResolvedHTTPProxy? {
        let value = ResolvedHTTPProxy(settings)
        lock.lock()
        resolved = value
        lock.unlock()
        return value
    }

    func reset() {
        update(ProxySettings())
    }
}

/// 代理相关纯函数（URLSession 配置字典构造等，便于测试）。
enum NetworkProxy {
    /// 构造 `URLSessionConfiguration.connectionProxyDictionary`。
    /// - 启用且合法：HTTP/HTTPS 同时指向代理，附带可选用户名/密码；
    /// - 禁用/非法：返回 nil（调用方清空代理字典）。
    static func connectionProxyDictionary(for proxy: ResolvedHTTPProxy?) -> [AnyHashable: Any]? {
        guard let proxy else { return nil }
        var dictionary: [AnyHashable: Any] = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: proxy.host,
            kCFNetworkProxiesHTTPPort: proxy.port,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: proxy.host,
            kCFNetworkProxiesHTTPSPort: proxy.port,
        ]
        if !proxy.username.isEmpty {
            dictionary[kCFProxyUsernameKey] = proxy.username
            // 同时提供字符串键，兼容部分 URLSession 版本对代理认证键的读取
            dictionary["ProxyUsername"] = proxy.username
        }
        if !proxy.password.isEmpty {
            dictionary[kCFProxyPasswordKey] = proxy.password
            dictionary["ProxyPassword"] = proxy.password
        }
        return dictionary
    }
}
