import Foundation
import Network
import SystemConfiguration

public struct ProxyEndpoint: Equatable {
    public let host: String
    public let port: Int

    public init?(host: String, port: Int) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard (1...65535).contains(port), !host.isEmpty,
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:").contains($0) }),
              !host.contains(":") || IPAddress.normalized(host) != nil else { return nil }
        self.host = host
        self.port = port
    }

    public var url: String {
        "http://\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }
}

public enum NetworkTransport: Equatable {
    case tunnel([String])
    case systemHTTPS(ProxyEndpoint)

    public var summary: String {
        switch self {
        case .tunnel(let interfaces): return "系统隧道 · \(interfaces.joined(separator: ", "))"
        case .systemHTTPS(let endpoint): return "系统 HTTPS 代理 · \(endpoint.host):\(endpoint.port)"
        }
    }

    public var proxyDictionary: [AnyHashable: Any] {
        var result: [AnyHashable: Any] = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                        "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        if case .systemHTTPS(let endpoint) = self {
            result["HTTPSEnable"] = 1
            result["HTTPSProxy"] = endpoint.host
            result["HTTPSPort"] = endpoint.port
        }
        return result
    }

    public func cliEnvironment(from environment: [String: String]) -> [String: String] {
        var result = environment
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                    "http_proxy", "https_proxy", "all_proxy", "no_proxy"] {
            result.removeValue(forKey: key)
        }
        if case .systemHTTPS(let endpoint) = self {
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] { result[key] = endpoint.url }
        }
        return result
    }

    public func requiresProcessRestart(after previous: NetworkTransport) -> Bool {
        guard self != previous else { return false }
        if case .tunnel = self, case .tunnel = previous { return false }
        return true
    }
}

public enum ProxyConfiguration: Equatable {
    case none
    case https(ProxyEndpoint)
    case unsupported(String)
}

public enum ProxyReachability: Equatable {
    case reachable
    case refused
    case unavailable
}

public struct NetworkInspection: Equatable {
    public let health: LocalHealth
    public let transport: NetworkTransport?

    public init(health: LocalHealth, transport: NetworkTransport? = nil) {
        self.health = health
        self.transport = transport
    }
}

public enum SystemProxyParser {
    private static let protectedHosts = ["www.cloudflare.com", "claude.ai", "api.anthropic.com", "platform.claude.com"]

    private static func enabled(_ value: Any?) -> Bool { (value as? NSNumber)?.intValue == 1 }

    public static func parse(_ values: [String: Any]) -> ProxyConfiguration {
        if enabled(values["ProxyAutoConfigEnable"]) || enabled(values["ProxyAutoDiscoveryEnable"]) {
            return .unsupported("检测到 PAC / 自动代理，暂不能确认各目标路径；请使用系统静态 HTTPS 代理或全局隧道。")
        }
        if let scoped = values["__SCOPED__"] as? [String: [String: Any]] {
            for configuration in scoped.values {
                let keys = ["HTTPSEnable", "HTTPSProxy", "HTTPSPort", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable", "ExceptionsList"]
                for key in keys {
                    let scopedValue = configuration[key] ?? (key.hasSuffix("Enable") ? 0 : "")
                    let globalValue = values[key] ?? (key.hasSuffix("Enable") ? 0 : "")
                    if !NSDictionary(dictionary: [key: scopedValue]).isEqual(to: [key: globalValue]) {
                        return .unsupported("存在不同的按网卡代理配置，暂不能确认统一路径。")
                    }
                }
            }
        }
        if enabled(values["HTTPSEnable"]) {
            guard let host = values["HTTPSProxy"] as? String, let port = values["HTTPSPort"] as? NSNumber,
                  let endpoint = ProxyEndpoint(host: host, port: port.intValue) else {
                return .unsupported("系统 HTTPS 代理地址或端口无效。")
            }
            for exception in values["ExceptionsList"] as? [String] ?? [] {
                let pattern = exception.lowercased().trimmingCharacters(in: .whitespaces)
                if pattern == "<local>" { continue }
                if pattern.contains("/") || IPAddress.normalized(pattern) != nil || (pattern.contains("*") && !pattern.hasSuffix(".local")) {
                    return .unsupported("系统代理包含 IP / 网段或通配绕过规则，暂不能确认目标是否被绕过。")
                }
                let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
                let expression = "^\(escaped)$"
                if protectedHosts.contains(where: { $0.range(of: expression, options: .regularExpression) != nil
                    || (pattern.hasPrefix(".") && ($0.hasSuffix(pattern) || $0 == String(pattern.dropFirst())))
                    || pattern.hasSuffix(".claude.ai") || pattern.hasSuffix(".anthropic.com") || pattern.hasSuffix(".claude.com") }) {
                    return .unsupported("系统代理例外规则可能绕过 Claude 或出口探针，请调整例外规则。")
                }
            }
            return .https(endpoint)
        }
        if enabled(values["SOCKSEnable"]) {
            return .unsupported("检测到仅 SOCKS 系统代理；当前请使用 HTTPS 系统代理或隧道模式。")
        }
        if enabled(values["HTTPEnable"]) {
            return .unsupported("仅 HTTP 系统代理不能确认 HTTPS 请求路径，请同时启用 HTTPS 代理或隧道。")
        }
        return .none
    }
}

private final class ConnectionOutcome {
    private let lock = NSLock()
    private var value: ProxyReachability = .unavailable

    func set(_ result: ProxyReachability) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func get() -> ProxyReachability {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public enum LocalInspector {
    public static func routeInterface(from output: String) -> String? {
        output.components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }?
            .components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
    }

    public static func isTunnel(_ interface: String) -> Bool {
        interface.range(of: "^(utun|tun|ppp|ipsec|wg)[0-9]+$", options: .regularExpression) != nil
    }

    public static func evaluate(proxy: ProxyConfiguration, routes: [String?], interfaces: Set<String>?,
                                reachability: (ProxyEndpoint) -> ProxyReachability) -> NetworkInspection {
        switch proxy {
        case .unsupported(let reason): return NetworkInspection(health: .unknown(reason))
        case .https(let endpoint):
            switch reachability(endpoint) {
            case .refused: return NetworkInspection(health: .unsafe("系统 HTTPS 代理端口拒绝连接，代理可能已退出。"))
            case .unavailable: return NetworkInspection(health: .unknown("系统代理暂时不可达，保留运行并继续检测。"))
            case .reachable:
                let transport = NetworkTransport.systemHTTPS(endpoint)
                return NetworkInspection(health: .healthy(interface: transport.summary), transport: transport)
            }
        case .none:
            guard let interfaces, routes.count >= 2, routes.allSatisfy({ $0 != nil && !$0!.isEmpty }) else {
                return NetworkInspection(health: .unknown("暂时无法确认系统路由，保留运行并等待重试。"))
            }
            let resolved = routes.compactMap { $0 }
            guard resolved.allSatisfy({ interfaces.contains($0) }) else {
                return NetworkInspection(health: .unknown("路由与网卡状态正在变化，等待重新检测。"))
            }
            guard resolved.allSatisfy(isTunnel) else {
                return NetworkInspection(health: .unsafe("未发现可用的系统 HTTPS 代理，且探测路由未全部经过隧道。"))
            }
            let transport = NetworkTransport.tunnel(Array(Set(resolved)).sorted())
            return NetworkInspection(health: .healthy(interface: transport.summary), transport: transport)
        }
    }

    public static func inspectConnection() -> NetworkInspection {
        guard let values = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return NetworkInspection(health: .unknown("无法读取 macOS 系统代理设置。"))
        }
        let proxy = SystemProxyParser.parse(values)
        if case .none = proxy {
            let result = Command.run("/sbin/ifconfig", ["-l"])
            let interfaces = result.status == 0 ? Set(result.output.split(whereSeparator: { $0.isWhitespace }).map(String.init)) : nil
            let routes = ["1.1.1.1", "8.8.8.8"].map { destination -> String? in
                let result = Command.run("/sbin/route", ["-n", "get", destination])
                return result.status == 0 ? routeInterface(from: result.output) : nil
            }
            return evaluate(proxy: proxy, routes: routes, interfaces: interfaces, reachability: checkEndpoint)
        }
        return evaluate(proxy: proxy, routes: [], interfaces: nil, reachability: checkEndpoint)
    }

    public static func checkEndpoint(_ endpoint: ProxyEndpoint) -> ProxyReachability {
        let outcome = ConnectionOutcome()
        let semaphore = DispatchSemaphore(value: 0)
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host),
                                      port: NWEndpoint.Port(rawValue: UInt16(endpoint.port))!, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: outcome.set(.reachable); semaphore.signal()
            case .failed(let error), .waiting(let error):
                if case .posix(let code) = error, code == .ECONNREFUSED { outcome.set(.refused) }
                semaphore.signal()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "guardian.proxy-probe"))
        let status = semaphore.wait(timeout: .now() + 2)
        connection.cancel()
        return status == .success ? outcome.get() : .unavailable
    }
}
