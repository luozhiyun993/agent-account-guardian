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
    public let executableVerified: Bool

    public init(pid: Int32, uid: UInt32, started: String, executable: String, executableVerified: Bool = true) {
        self.pid = pid
        self.uid = uid
        self.started = started
        self.executable = executable
        self.executableVerified = executableVerified
    }

    func resolvingExecutable(_ path: String?) -> ProcessIdentity {
        guard let path, path.hasPrefix("/") else { return self }
        return ProcessIdentity(pid: pid, uid: uid, started: started, executable: path)
    }

    public static func parse(_ line: String) -> ProcessIdentity? {
        let fields = line.split(maxSplits: 7, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        guard fields.count == 8, let pid = Int32(fields[0]), let uid = UInt32(fields[1]), pid > 1 else { return nil }
        return ProcessIdentity(pid: pid, uid: uid, started: fields[2...6].joined(separator: " "),
                               executable: String(fields[7]).trimmingCharacters(in: .whitespaces), executableVerified: false)
    }
}

public struct ProcessInspection {
    public let targets: [ProcessIdentity]
    public let failureReason: String?

    public init(targets: [ProcessIdentity], failureReason: String? = nil) {
        self.targets = targets
        self.failureReason = failureReason
    }

    public var health: ProcessHealth {
        guard let failureReason else { return .healthy(count: targets.count) }
        return targets.isEmpty ? .unknown(failureReason) : .partial(count: targets.count, reason: failureReason)
    }
}

public enum ProcessInspector {
    public static func snapshot() -> [ProcessIdentity]? {
        let result = Command.run("/bin/ps", ["-axo", "pid=,uid=,lstart=,comm="])
        guard result.status == 0 else { return nil }
        return result.output.split(separator: "\n").compactMap { line in
            guard let identity = ProcessIdentity.parse(String(line)) else { return nil }
            guard identity.uid == getuid(), identity.pid != getpid() else { return identity }
            return identity.resolvingExecutable(executablePath(pid: identity.pid))
        }
    }

    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard count > 0 else { return kernelExecutablePath(pid: pid) }
        let path = String(cString: buffer)
        return path.hasPrefix("/") ? path : kernelExecutablePath(pid: pid)
    }

    private static func kernelArgumentsData(pid: Int32) -> Data? {
        var request = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&request, u_int(request.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size < 2_097_152 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&request, u_int(request.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= buffer.count else { return nil }
        return Data(buffer.prefix(size))
    }

    static func executablePath(fromKernelArguments data: Data) -> String? {
        let bytes = [UInt8](data)
        let start = MemoryLayout<Int32>.size
        guard bytes.count > start,
              let end = bytes[start...].firstIndex(of: 0), end > start,
              let path = String(bytes: bytes[start..<end], encoding: .utf8), path.hasPrefix("/") else { return nil }
        return path
    }

    private static func kernelExecutablePath(pid: Int32) -> String? {
        // KERN_PROCARGS2 starts with the kernel's executable path, before argv/env.
        // Use only that path as fallback; never use mutable argv[0] to verify identity.
        guard let data = kernelArgumentsData(pid: pid) else { return nil }
        return executablePath(fromKernelArguments: data)
    }

    private static func desktopPath(_ path: String) -> Bool {
        InstallationDiscovery.desktopApplication(containingExecutable: path) != nil
    }

    static func hasUnresolvedCandidate(_ identity: ProcessIdentity, settings: GuardianSettings,
                                       uid: UInt32 = getuid(), cliExecutable: String? = nil,
                                       arguments: [String] = [], installations: ClaudeInstallations? = nil,
                                       workingDirectory: String? = nil) -> Bool {
        guard identity.uid == uid, identity.pid != getpid(), !identity.executableVerified else { return false }
        let name = URL(fileURLWithPath: identity.executable).lastPathComponent.lowercased()
        let desktop = installations?.containsDesktopExecutable(identity.executable) ?? desktopPath(identity.executable)
        if settings.protectDesktop, desktop || name == "claude" { return true }
        guard settings.protectCLI else { return false }
        if name == "claude" || identity.executable == cliExecutable { return true }
        if let installations, installations.nativeExecutables.contains(InstallationDiscovery.canonical(identity.executable)) { return true }
        return ["node", "bun"].contains(name) && isCLIEntrypoint(arguments, cliExecutable: cliExecutable,
            installations: installations, workingDirectory: workingDirectory)
    }

    static func isCLIEntrypoint(_ arguments: [String], cliExecutable: String?,
                               installations: ClaudeInstallations? = nil, workingDirectory: String? = nil) -> Bool {
        guard let entry = InstallationDiscovery.scriptArgument(arguments, workingDirectory: workingDirectory) else { return false }
        if let installations, installations.scriptEntrypoints.contains(entry) { return true }
        if let cliExecutable, entry == InstallationDiscovery.canonical(cliExecutable) { return true }
        // The manifest declares the package identity and CLI bin entry, independent of installation location/name.
        return InstallationDiscovery.packageEntrypoint(containing: entry) == entry
    }

    public static func arguments(pid: Int32) -> [String] {
        guard let data = kernelArgumentsData(pid: pid) else { return [] }
        let buffer = [UInt8](data)
        let size = buffer.count
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
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

    public static func claudeCommand(settings: GuardianSettings = GuardianSettings()) -> URL? {
        InstallationDiscovery.discover(settings: settings).cliCommands.first
    }

    public static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.hasPrefix("/") ? path : nil
    }

    public static func isProtected(_ identity: ProcessIdentity, settings: GuardianSettings,
                                   uid: UInt32 = getuid(), cliExecutable: String? = nil,
                                   arguments: [String] = [], installations: ClaudeInstallations? = nil,
                                   workingDirectory: String? = nil) -> Bool {
        guard identity.uid == uid, identity.pid != getpid(), identity.executableVerified else { return false }
        let desktop = installations?.containsDesktopExecutable(identity.executable) ?? desktopPath(identity.executable)
        if settings.protectDesktop, desktop { return true }
        guard settings.protectCLI else { return false }
        if identity.executable == cliExecutable { return true }
        if let installations, installations.nativeExecutables.contains(InstallationDiscovery.canonical(identity.executable)) { return true }
        let name = URL(fileURLWithPath: identity.executable).lastPathComponent.lowercased()
        return ["node", "bun"].contains(name) && isCLIEntrypoint(arguments, cliExecutable: cliExecutable,
            installations: installations, workingDirectory: workingDirectory)
    }

    enum ProcessLifecycle {
        case running, gone, unknown
    }

    static func lifecycle(pid: Int32) -> ProcessLifecycle {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        errno = 0
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        if count == size { return info.pbi_status == UInt32(SZOMB) ? .gone : .running }
        return errno == ESRCH ? .gone : .unknown
    }

    static func evaluate(_ processes: [ProcessIdentity], settings: GuardianSettings,
                         uid: UInt32 = getuid(), cliExecutable: String? = nil,
                         installations: ClaudeInstallations? = nil,
                         arguments: (Int32) -> [String], lifecycle: (Int32) -> ProcessLifecycle,
                         workingDirectory: (Int32) -> String? = { _ in nil }) -> ProcessInspection {
        var targets: [ProcessIdentity] = []
        var unresolved = 0
        for identity in processes where identity.uid == uid && identity.pid != getpid() {
            let name = URL(fileURLWithPath: identity.executable).lastPathComponent.lowercased()
            let entryArguments = settings.protectCLI && ["node", "bun"].contains(name) ? arguments(identity.pid) : []
            let directory = entryArguments.count > 1 ? workingDirectory(identity.pid) : nil
            if isProtected(identity, settings: settings, uid: uid, cliExecutable: cliExecutable,
                           arguments: entryArguments, installations: installations, workingDirectory: directory) {
                targets.append(identity)
            } else if hasUnresolvedCandidate(identity, settings: settings, uid: uid,
                                             cliExecutable: cliExecutable, arguments: entryArguments,
                                             installations: installations, workingDirectory: directory) {
                // A process that has exited cannot send traffic and must not keep the gate closed.
                if case .gone = lifecycle(identity.pid) { continue }
                unresolved += 1
            }
        }
        let reason = unresolved == 0 ? nil : "有 \(unresolved) 个 Claude 候选进程暂时无法核实，启动门禁保持关闭；已核实目标仍可执行急停。"
        return ProcessInspection(targets: targets, failureReason: reason)
    }

    public static func inspect(settings: GuardianSettings) -> ProcessInspection {
        guard let processes = snapshot() else {
            return ProcessInspection(targets: [], failureReason: "无法读取系统进程列表，启动门禁保持关闭。")
        }
        let installations = InstallationDiscovery.discover(settings: settings, processes: processes)
        return evaluate(processes, settings: settings, installations: installations,
                        arguments: arguments, lifecycle: lifecycle, workingDirectory: workingDirectory)
    }

    public static func protectedProcesses(settings: GuardianSettings) -> [ProcessIdentity]? {
        let result = inspect(settings: settings)
        return result.failureReason == nil ? result.targets : nil
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
        let verified = targets.filter { target in
            target.executableVerified && current.contains(target) && target.uid == getuid() && target.pid != getpid()
        }
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
        report.stopped = verified.filter { target in
            !final.contains { $0.pid == target.pid && $0.uid == target.uid && $0.started == target.started }
        }.count
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
