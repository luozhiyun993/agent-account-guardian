import Foundation
import Darwin

public struct CommandResult {
    public let status: Int32
    public let output: String
}

public enum Command {
    public static func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        } catch {
            return CommandResult(status: -1, output: "")
        }
    }
}

public struct ProcessIdentity: Equatable {
    public let pid: Int32
    public let uid: UInt32
    public let started: String
    public let executable: String

    public init(pid: Int32, uid: UInt32, started: String, executable: String) {
        self.pid = pid
        self.uid = uid
        self.started = started
        self.executable = executable
    }

    public static func parse(_ line: String) -> ProcessIdentity? {
        let fields = line.split(maxSplits: 7, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        guard fields.count == 8, let pid = Int32(fields[0]), let uid = UInt32(fields[1]), pid > 1 else { return nil }
        return ProcessIdentity(pid: pid, uid: uid, started: fields[2...6].joined(separator: " "),
                               executable: String(fields[7]).trimmingCharacters(in: .whitespaces))
    }
}

public enum ProcessInspector {
    public static func snapshot() -> [ProcessIdentity]? {
        let result = Command.run("/bin/ps", ["-axo", "pid=,uid=,lstart=,comm="])
        guard result.status == 0 else { return nil }
        return result.output.split(separator: "\n").compactMap { ProcessIdentity.parse(String($0)) }
    }

    public static func arguments(pid: Int32) -> [String] {
        var request = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&request, u_int(request.count), nil, &size, nil, 0) == 0, size > 4, size < 2_097_152 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&request, u_int(request.count), &buffer, &size, nil, 0) == 0 else { return [] }
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count < 8192 else { return [] }
        var position = MemoryLayout<Int32>.size
        while position < size && buffer[position] != 0 { position += 1 }
        while position < size && buffer[position] == 0 { position += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            let start = position
            while position < size && buffer[position] != 0 { position += 1 }
            guard position < size else { return [] }
            arguments.append(String(decoding: buffer[start..<position], as: UTF8.self))
            position += 1
        }
        return arguments
    }

    public static func claudeCommand() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                "\(home)/.claude/local/claude"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func isProtected(_ identity: ProcessIdentity, settings: GuardianSettings,
                                   uid: UInt32 = getuid(), cliExecutable: String? = nil,
                                   arguments: [String] = []) -> Bool {
        guard identity.uid == uid, identity.pid != getpid() else { return false }
        if settings.protectDesktop {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for root in ["/Applications/Claude.app/Contents/", "\(home)/Applications/Claude.app/Contents/"] {
                if identity.executable.hasPrefix(root) { return true }
            }
        }
        guard settings.protectCLI, let cliExecutable else { return false }
        if identity.executable == cliExecutable { return true }
        let name = URL(fileURLWithPath: identity.executable).lastPathComponent
        guard ["node", "bun"].contains(name), arguments.count > 1,
              cliExecutable.hasSuffix("/@anthropic-ai/claude-code/cli.js") else { return false }
        return URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath().path == cliExecutable
    }

    public static func protectedProcesses(settings: GuardianSettings) -> [ProcessIdentity]? {
        guard let processes = snapshot() else { return nil }
        let cli = claudeCommand()?.resolvingSymlinksInPath().path
        return processes.filter { identity in
            guard identity.uid == getuid() else { return false }
            let name = URL(fileURLWithPath: identity.executable).lastPathComponent
            let arguments = ["node", "bun"].contains(name) ? arguments(pid: identity.pid) : []
            return isProtected(identity, settings: settings, cliExecutable: cli, arguments: arguments)
        }
    }
}

public struct StopReport {
    public var stopped = 0
    public var failed = 0
    public var inspectionFailed = false
    public init() {}
}

public enum ProcessStopper {
    public static func stop(_ targets: [ProcessIdentity]) async -> StopReport {
        var report = StopReport()
        guard let current = ProcessInspector.snapshot() else { report.inspectionFailed = true; return report }
        let verified = targets.filter { target in current.contains(target) && target.uid == getuid() && target.pid != getpid() }
        for target in verified {
            if kill(target.pid, SIGTERM) != 0 && errno != ESRCH { report.failed += 1 }
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let remaining = ProcessInspector.snapshot() else { report.inspectionFailed = true; return report }
        for target in verified {
            if remaining.contains(target) {
                if kill(target.pid, SIGKILL) != 0 && errno != ESRCH { report.failed += 1 }
            }
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard let final = ProcessInspector.snapshot() else { report.inspectionFailed = true; return report }
        report.stopped = verified.filter { !final.contains($0) }.count
        report.failed = max(report.failed, verified.count - report.stopped)
        return report
    }
}

public enum LocalInspector {
    public static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mihomo-party/mihomo.yaml")

    public static func tunDevice(from yaml: String) -> (enabled: Bool?, device: String?) {
        var inside = false
        var enabled: Bool?
        var device: String?
        for line in yaml.components(separatedBy: .newlines) {
            if line == "tun:" { inside = true; continue }
            if inside && !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("#") { break }
            guard inside else { continue }
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            let value = fields[1].components(separatedBy: " #")[0]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if fields[0] == "enable" { enabled = value == "true" ? true : value == "false" ? false : nil }
            if fields[0] == "device", value.hasPrefix("utun"), value.dropFirst(4).allSatisfy({ $0.isNumber }), value.count > 4 {
                device = value
            }
        }
        return (enabled, device)
    }

    public static func inspect() -> LocalHealth {
        guard let processes = ProcessInspector.snapshot() else { return .unknown("无法读取进程状态，检查系统权限。") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ["/Applications/Clash Party.app/Contents/Resources/sidecar/",
                     "\(home)/Applications/Clash Party.app/Contents/Resources/sidecar/"]
        let names = ["mihomo", "mihomo-alpha", "mihomo-smart"]
        let kernel = processes.contains { process in
            roots.contains { root in names.contains { process.executable == root + $0 } }
        }
        guard kernel else { return .unsafe("Clash Party 代理内核未运行。") }
        guard let yaml = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .unknown("无法读取 Clash Party 的 TUN 配置。")
        }
        let config = tunDevice(from: yaml)
        if config.enabled == false { return .unsafe("Clash Party 的 TUN 已关闭。") }
        guard config.enabled == true, let device = config.device else {
            return .unknown("无法确认 Clash Party 的 TUN 网卡；请在 Clash Party 开启 TUN。")
        }
        let interfaces = Command.run("/sbin/ifconfig", ["-l"])
        guard interfaces.status == 0 else { return .unknown("无法读取系统网卡。") }
        guard interfaces.output.split(whereSeparator: { $0.isWhitespace }).contains(Substring(device)) else {
            return .unsafe("Clash Party 的 TUN 网卡 \(device) 已消失。")
        }
        for destination in ["1.1.1.1", "8.8.8.8"] {
            let route = Command.run("/sbin/route", ["-n", "get", destination])
            guard route.status == 0 else { return .unknown("暂时无法确认路由；保留运行并等待重试。") }
            let interface = route.output.components(separatedBy: .newlines)
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }?
                .components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
            guard let interface else { return .unknown("未取得有效的出口路由。") }
            if interface != device { return .unsafe("出口路由已离开 Clash Party 的 TUN 网卡。") }
        }
        return .healthy(interface: device)
    }
}

public enum ExitInspector {
    public static func inspect() async -> ExitHealth {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.host == "www.cloudflare.com", data.count < 16_384,
                  let text = String(data: data, encoding: .utf8), let result = ExitObservation.parse(text) else {
                return .unknown("出口服务未返回有效 IP 和地区；继续检测，不急停。")
            }
            return .known(result)
        } catch {
            return .unknown("网络不通或出口检测超时；继续检测，不急停。")
        }
    }
}
