import Foundation
import Darwin

public struct GuardianSettings: Codable, Equatable {
    public var country = "JP"
    public var pinnedIP = ""
    public var pinEnabled = false
    public var protectDesktop = true
    public var protectCLI = true

    public init() {}

    public var validationError: String? {
        if country.count != 2 || !country.utf8.allSatisfy({ (65...90).contains($0) }) {
            return "目标地区需要填写两位大写国家代码，例如 JP。"
        }
        if pinEnabled && IPAddress.normalized(pinnedIP) == nil {
            return "请输入有效的公网 IPv4 或 IPv6 地址，不包含端口。"
        }
        if pinEnabled && !IPAddress.isPublic(pinnedIP) {
            return "指定出口应为公网地址，不能使用本机、局域网或 Fake-IP 地址。"
        }
        if !protectDesktop && !protectCLI { return "至少选择一个保护对象。" }
        return nil
    }
}

public enum IPAddress {
    public static func normalized(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        } else if inet_pton(AF_INET6, value, &ipv6) == 1 {
            guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        } else {
            return nil
        }
        return String(cString: buffer)
    }

    public static func isPublic(_ value: String) -> Bool {
        guard let normalized = normalized(value) else { return false }
        if normalized.contains(":") {
            guard let first = normalized.split(separator: ":").first,
                  let prefix = UInt16(first, radix: 16) else { return false }
            return (0x2000...0x3fff).contains(prefix) && !normalized.hasPrefix("2001:db8:")
        }
        let bytes = normalized.split(separator: ".").compactMap { Int($0) }
        guard bytes.count == 4 else { return false }
        return !(bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127 || bytes[0] >= 224
            || (bytes[0] == 169 && bytes[1] == 254)
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 100 && (64...127).contains(bytes[1]))
            || (bytes[0] == 198 && (18...19).contains(bytes[1])))
    }
}

public enum LocalHealth: Equatable {
    case healthy(interface: String)
    case unsafe(String)
    case unknown(String)

    public var summary: String {
        switch self {
        case .healthy(let interface): return "Clash Party 内核在线 · 路由经 \(interface)"
        case .unsafe(let reason), .unknown(let reason): return reason
        }
    }
}

public struct ExitObservation: Equatable {
    public let ip: String
    public let country: String
    public let timestamp: Date

    public init(ip: String, country: String, timestamp: Date = Date()) {
        self.ip = ip
        self.country = country
        self.timestamp = timestamp
    }

    public static func parse(_ text: String, now: Date = Date()) -> ExitObservation? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if fields[pair[0]] != nil { return nil }
            fields[pair[0]] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let rawIP = fields["ip"], let ip = IPAddress.normalized(rawIP),
              IPAddress.isPublic(ip), let country = fields["loc"],
              country.count == 2, country != "XX", country != "T1",
              country.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return ExitObservation(ip: ip, country: country, timestamp: now)
    }
}

public enum ExitHealth: Equatable {
    case known(ExitObservation)
    case unknown(String)
}

public enum Decision: Equatable {
    case allow
    case warn(String)
    case trip(String)
    case wait(String)

    public var mayLaunch: Bool {
        switch self {
        case .allow, .warn: return true
        case .trip, .wait: return false
        }
    }
}

public enum GuardianPolicy {
    public static func evaluate(settings: GuardianSettings, local: LocalHealth,
                                exit: ExitHealth, previousIP: String? = nil,
                                now: Date = Date()) -> Decision {
        if let error = settings.validationError { return .wait(error) }
        if case .unsafe(let reason) = local { return .trip(reason) }
        if case .known(let observation) = exit {
            guard now.timeIntervalSince(observation.timestamp) >= -5,
                  now.timeIntervalSince(observation.timestamp) <= 25 else {
                return .wait("出口信息已过期，等待重新检测。")
            }
            if settings.pinEnabled,
               IPAddress.normalized(settings.pinnedIP) != IPAddress.normalized(observation.ip) {
                return .trip("出口 IP 与手动指定的地址不一致。")
            }
            if observation.country != settings.country {
                return .trip("出口地区为 \(observation.country)，目标地区为 \(settings.country)。")
            }
        }
        if case .unknown(let reason) = local { return .wait(reason) }
        guard case .known(let observation) = exit else {
            if case .unknown(let reason) = exit { return .wait(reason) }
            return .wait("等待出口检测。")
        }
        if let previousIP, previousIP != observation.ip {
            return .warn("出口 IP 已变化，地区仍符合要求。")
        }
        return .allow
    }
}

public struct ProtectionState: Codable {
    public var settings = GuardianSettings()
    public var enabled = false
    public var lockedReason: String?
    public var heartbeat = Date.distantPast
    public var lastIP: String?

    public init() {}

    public mutating func observe(_ decision: Decision) {
        guard enabled, lockedReason == nil else { return }
        if case .trip(let reason) = decision { lockedReason = reason }
    }

    public mutating func recover(_ decision: Decision) -> Bool {
        guard enabled, decision.mayLaunch else { return false }
        lockedReason = nil
        return true
    }

    public func permitsLaunch(_ decision: Decision, now: Date = Date()) -> Bool {
        enabled && lockedReason == nil && decision.mayLaunch
            && now.timeIntervalSince(heartbeat) >= -5 && now.timeIntervalSince(heartbeat) < 8
    }
}

public struct StateStore {
    public let directory: URL
    public var url: URL { directory.appendingPathComponent("state.json") }

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentAccountGuardian")) {
        self.directory = directory
    }

    public func load() throws -> ProtectionState {
        guard FileManager.default.fileExists(atPath: url.path) else { return ProtectionState() }
        return try JSONDecoder().decode(ProtectionState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: ProtectionState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
