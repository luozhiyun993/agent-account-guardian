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

public enum ExitInspector {
    public static func configuration(transport: NetworkTransport) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.connectionProxyDictionary = transport.proxyDictionary
        return config
    }

    public static func inspect(transport: NetworkTransport) async -> ExitHealth {
        let config = configuration(transport: transport)
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
