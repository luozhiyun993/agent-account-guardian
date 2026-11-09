import AppKit
import Foundation

public struct ClaudeInstallations {
    public var desktopApplications: [URL]
    public var cliCommands: [URL]
    public var nativeExecutables: Set<String>
    public var scriptEntrypoints: Set<String>

    public init(desktopApplications: [URL] = [], cliCommands: [URL] = [],
                nativeExecutables: Set<String> = [], scriptEntrypoints: Set<String> = []) {
        self.desktopApplications = desktopApplications
        self.cliCommands = cliCommands
        self.nativeExecutables = nativeExecutables
        self.scriptEntrypoints = scriptEntrypoints
    }

    public func containsDesktopExecutable(_ path: String) -> Bool {
        let path = InstallationDiscovery.canonical(path)
        return desktopApplications.contains {
            let root = InstallationDiscovery.canonical($0.appendingPathComponent("Contents").path) + "/"
            return path.hasPrefix(root)
        }
    }
}

public enum InstallationDiscovery {
    // Application/package identities are stable product identifiers, not machine-specific paths.
    public static let desktopBundleIdentifier = "com.anthropic.claudefordesktop"
    public static let cliPackageName = "@anthropic-ai/claude-code"

    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_048_576, let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return values
    }

    public static func validatedDesktopApplication(_ url: URL) -> URL? {
        let url = URL(fileURLWithPath: canonical(url.path), isDirectory: true)
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              bundle.bundleIdentifier == desktopBundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return url
    }

    public static func desktopApplication(containingExecutable path: String) -> URL? {
        var parent = URL(fileURLWithPath: canonical(path)).deletingLastPathComponent()
        for _ in 0..<24 {
            if parent.pathExtension.lowercased() == "app", let app = validatedDesktopApplication(parent) { return app }
            let next = parent.deletingLastPathComponent()
            if next == parent { break }
            parent = next
        }
        return nil
    }

    private static func versionBinDirectories(_ root: URL, suffix: String = "bin") -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return children.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(256).compactMap {
            guard (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return $0.appendingPathComponent(suffix, isDirectory: true)
        }
    }

    static func commandCandidates(home: URL, environment: [String: String], customPath: String) -> [URL] {
        var candidates: [URL] = []
        if !customPath.isEmpty { candidates.append(URL(fileURLWithPath: canonical(customPath))) }
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        directories += [home.appendingPathComponent(".local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"),
                        URL(fileURLWithPath: "/usr/local/bin"), home.appendingPathComponent(".claude/local"),
                        home.appendingPathComponent(".npm-global/bin"), home.appendingPathComponent(".volta/bin"),
                        home.appendingPathComponent(".asdf/shims"), home.appendingPathComponent(".local/share/mise/shims")]
        for key in ["NPM_CONFIG_PREFIX", "npm_config_prefix", "VOLTA_HOME"] {
            if let value = environment[key], value.hasPrefix("/") {
                directories.append(URL(fileURLWithPath: value).appendingPathComponent("bin"))
            }
        }
        let nvm = environment["NVM_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".nvm")
        let asdf = environment["ASDF_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".asdf")
        directories += versionBinDirectories(nvm.appendingPathComponent("versions/node"))
        directories += versionBinDirectories(asdf.appendingPathComponent("installs/nodejs"))
        directories += versionBinDirectories(home.appendingPathComponent(".local/share/mise/installs/node"))
        directories += versionBinDirectories(home.appendingPathComponent(".local/share/fnm/node-versions"), suffix: "installation/bin")
        directories += versionBinDirectories(home.appendingPathComponent(".fnm/node-versions"), suffix: "installation/bin")
        candidates += directories.map { $0.appendingPathComponent("claude") }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func packageEntrypoint(containing path: String) -> String? {
        let candidate = URL(fileURLWithPath: canonical(path))
        var directory = candidate.deletingLastPathComponent()
        for _ in 0..<8 {
            let manifest = directory.appendingPathComponent("package.json")
            if let values = readJSON(manifest), values["name"] as? String == cliPackageName {
                let bin: String?
                if let mapping = values["bin"] as? [String: String] { bin = mapping["claude"] }
                else { bin = values["bin"] as? String }
                guard let bin, !bin.hasPrefix("/"), !bin.contains("\0") else { return nil }
                let root = canonical(directory.path) + "/"
                let entry = canonical(directory.appendingPathComponent(bin).path)
                guard entry.hasPrefix(root), entry == candidate.path,
                      FileManager.default.fileExists(atPath: entry) else { return nil }
                return entry
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }

    static func scriptArgument(_ arguments: [String], workingDirectory: String? = nil) -> String? {
        guard arguments.count > 1 else { return nil }
        let runtime = URL(fileURLWithPath: arguments[0]).lastPathComponent.lowercased()
        var index = 1
        if runtime == "bun", arguments[index] == "run" { index += 1 }
        let valueOptions: Set<String> = ["-r", "--require", "--import", "--loader", "--experimental-loader", "--conditions", "-C"]
        let booleanOptions: Set<String> = ["--no-warnings", "--trace-warnings", "--enable-source-maps", "--inspect", "--inspect-brk", "--experimental-modules"]
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { index += 1; break }
            if ["-e", "--eval", "-p", "--print"].contains(argument)
                || argument.hasPrefix("--eval=") || argument.hasPrefix("--print=") { return nil }
            if valueOptions.contains(argument) { index += 2; continue }
            if booleanOptions.contains(argument) || (argument.hasPrefix("--") && argument.contains("=")) {
                index += 1; continue
            }
            if argument.hasPrefix("-") { return nil }
            break
        }
        guard index < arguments.count else { return nil }
        let path = arguments[index]
        guard !path.isEmpty, !path.contains("\0"), !path.contains("://") else { return nil }
        if path.hasPrefix("/") { return canonical(path) }
        guard let workingDirectory, workingDirectory.hasPrefix("/") else { return nil }
        return canonical(URL(fileURLWithPath: workingDirectory).appendingPathComponent(path).path)
    }

    static func isNativeExecutable(_ path: String) -> Bool {
        guard !["node", "bun"].contains(URL(fileURLWithPath: path).lastPathComponent.lowercased()),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = [UInt8](data)
        return [[0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf],
                [0xfe, 0xed, 0xfa, 0xce], [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
                [0xca, 0xfe, 0xba, 0xbf]].contains(magic)
    }

    public static func discover(settings: GuardianSettings = GuardianSettings(),
                                processes: [ProcessIdentity] = [],
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeInstallations {
        var result = ClaudeInstallations()
        var desktopCandidates: [URL] = []
        if !settings.desktopApplicationPath.isEmpty {
            desktopCandidates.append(URL(fileURLWithPath: canonical(settings.desktopApplicationPath)))
        }
        desktopCandidates += NSWorkspace.shared.urlsForApplications(withBundleIdentifier: desktopBundleIdentifier)
        desktopCandidates += NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundleIdentifier).compactMap(\.bundleURL)
        desktopCandidates += processes.filter { $0.uid == getuid() && $0.executableVerified }
            .compactMap { desktopApplication(containingExecutable: $0.executable) }
        var desktopSeen: Set<String> = []
        result.desktopApplications = desktopCandidates.compactMap(validatedDesktopApplication)
            .filter { desktopSeen.insert($0.path).inserted }

        var executableSeen: Set<String> = []
        for command in commandCandidates(home: home, environment: environment, customPath: settings.cliExecutablePath) {
            guard FileManager.default.isExecutableFile(atPath: command.path) else { continue }
            let actual = canonical(command.path)
            guard executableSeen.insert(actual).inserted else { continue }
            result.cliCommands.append(command.standardizedFileURL)
            if let script = packageEntrypoint(containing: actual) {
                result.scriptEntrypoints.insert(script)
            } else if isNativeExecutable(actual) {
                result.nativeExecutables.insert(actual)
            }
        }
        // Keep older native installations observable after the current symlink changes on upgrade.
        let versions = home.appendingPathComponent(".local/share/claude/versions")
        if let files = try? FileManager.default.contentsOfDirectory(at: versions,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for file in files.prefix(256) where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && FileManager.default.isExecutableFile(atPath: file.path) && isNativeExecutable(file.path) {
                result.nativeExecutables.insert(canonical(file.path))
            }
        }
        return result
    }
}
