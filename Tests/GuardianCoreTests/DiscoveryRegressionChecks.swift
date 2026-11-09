import Foundation
#if canImport(GuardianCore)
@testable import GuardianCore
#endif

/// Dependency-free regression assertions shared by XCTest and the CLI-tools-only runner.
func discoveryRegressionChecks() throws -> Int {
    var checks = 0
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: "DiscoveryRegression", code: checks,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    var root = FileManager.default.temporaryDirectory.appendingPathComponent("guardian-discovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    root = URL(fileURLWithPath: InstallationDiscovery.canonical(root.path), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ data: Data, executable: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        return url
    }
    let old = Data("{\"country\":\"US\",\"pinnedIP\":\"\",\"pinEnabled\":false,\"protectDesktop\":true,\"protectCLI\":true}".utf8)
    let migrated = try JSONDecoder().decode(GuardianSettings.self, from: old)
    try require(migrated.country == "US" && migrated.desktopApplicationPath.isEmpty && migrated.cliExecutablePath.isEmpty, "Old settings must migrate without losing rules")
    var custom = migrated
    custom.desktopApplicationPath = root.appendingPathComponent("Renamed Desktop.app").path
    custom.cliExecutablePath = root.appendingPathComponent("tools/bin/claude").path
    let restored = try JSONDecoder().decode(GuardianSettings.self, from: JSONEncoder().encode(custom))
    try require(restored == custom, "Custom paths must round-trip")
    custom.cliExecutablePath = "relative/path"
    try require(custom.validationError != nil, "Relative custom path must be rejected")
    custom.cliExecutablePath = "~/tools/claude"
    try require(custom.validationError == nil, "Home-relative path must be accepted")

    let bundle = root.appendingPathComponent("Renamed Desktop.app")
    let executable = try write("Renamed Desktop.app/Contents/MacOS/DesktopMain", Data("#!/bin/sh\nexit 0\n".utf8), executable: true)
    let plist: [String: Any] = ["CFBundleIdentifier": InstallationDiscovery.desktopBundleIdentifier,
                              "CFBundleExecutable": "DesktopMain", "CFBundlePackageType": "APPL"]
    _ = try write("Renamed Desktop.app/Contents/Info.plist", PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    try require(InstallationDiscovery.validatedDesktopApplication(bundle)?.path == bundle.path, "Renamed custom Desktop must be discovered by bundle ID")
    try require(InstallationDiscovery.desktopApplication(containingExecutable: executable.path)?.path == bundle.path, "Executable ancestry must discover custom app")
    let helper = try write("Renamed Desktop.app/Contents/Helpers/Helper.app/Contents/MacOS/Helper", Data("helper".utf8))
    try require(InstallationDiscovery.desktopApplication(containingExecutable: helper.path)?.path == bundle.path, "Nested helper must resolve to the outer Desktop")
    let installations = ClaudeInstallations(desktopApplications: [bundle])
    try require(installations.containsDesktopExecutable(helper.path), "Known helper must be protected")
    try require(!installations.containsDesktopExecutable(bundle.path + ".fake/Contents/MacOS/DesktopMain"), "Similar bundle path must not match")
    let bad = root.appendingPathComponent("Not Claude.app")
    _ = try write("Not Claude.app/Contents/MacOS/Main", Data("#!/bin/sh\n".utf8), executable: true)
    _ = try write("Not Claude.app/Contents/Info.plist", PropertyListSerialization.data(fromPropertyList:
        ["CFBundleIdentifier": "org.example.other", "CFBundleExecutable": "Main"], format: .xml, options: 0))
    try require(InstallationDiscovery.validatedDesktopApplication(bad) == nil, "Wrong product bundle ID must be rejected")

    let script = try write("npm-custom/renamed-start.js", Data("#!/usr/bin/env node\n".utf8), executable: true)
    let manifest = ["name": InstallationDiscovery.cliPackageName, "bin": ["claude": "renamed-start.js"]] as [String: Any]
    _ = try write("npm-custom/package.json", JSONSerialization.data(withJSONObject: manifest))
    try require(InstallationDiscovery.packageEntrypoint(containing: script.path) == script.path, "Package bin declaration must work without cli.js hardcode")
    let otherScript = try write("npm-custom/other.js", Data("test".utf8))
    try require(InstallationDiscovery.packageEntrypoint(containing: otherScript.path) == nil, "Other script in same package must not match")
    try require(ProcessInspector.isCLIEntrypoint(["node", "--no-warnings", "--require", "/tmp/preload.js", script.path], cliExecutable: nil), "Extra Node options must not hide actual CLI script")
    try require(ProcessInspector.isCLIEntrypoint(["node", "renamed-start.js"], cliExecutable: nil, workingDirectory: script.deletingLastPathComponent().path), "Relative script must resolve using process cwd")
    try require(ProcessInspector.isCLIEntrypoint(["bun", "run", script.path], cliExecutable: nil), "Bun run script must match")
    try require(!ProcessInspector.isCLIEntrypoint(["node", "-e", script.path], cliExecutable: nil), "Eval mention must never authorize a target")
    try require(!ProcessInspector.isCLIEntrypoint(["node", "--eval=" + script.path], cliExecutable: nil), "Inline eval must never authorize")
    try require(InstallationDiscovery.scriptArgument(["node", "--unknown-option", script.path]) == nil, "Ambiguous runtime options must not authorize")
    let unrelatedScript = try write("other-package/start.js", Data("test".utf8))
    _ = try write("other-package/package.json", JSONSerialization.data(withJSONObject: ["name": "other-package", "bin": ["claude": "start.js"]]))
    try require(!ProcessInspector.isCLIEntrypoint(["node", unrelatedScript.path], cliExecutable: nil), "Unrelated package using claude command name must not match")

    let native = try write("tools/bin/claude", Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]), executable: true)
    let oldNative = try write(".local/share/claude/versions/older", Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]), executable: true)
    let nvm = try write(".nvm/versions/node/v99/bin/claude", Data("#!/bin/sh\n".utf8), executable: true)
    let candidates = InstallationDiscovery.commandCandidates(home: root, environment: ["PATH": native.deletingLastPathComponent().path + ":relative:" + native.deletingLastPathComponent().path], customPath: native.path)
    try require(candidates.filter { $0.path == native.path }.count == 1, "PATH candidates must be deduplicated")
    try require(candidates.contains { InstallationDiscovery.canonical($0.path) == InstallationDiscovery.canonical(nvm.path) }, "nvm custom versions must be discovered")
    try require(candidates.allSatisfy { $0.path.hasPrefix("/") }, "Relative PATH entries must not become candidates")
    custom.cliExecutablePath = native.path
    custom.desktopApplicationPath = bundle.path
    let discovered = InstallationDiscovery.discover(settings: custom, environment: ["PATH": native.deletingLastPathComponent().path], home: root)
    try require(discovered.desktopApplications.first?.path == bundle.path, "Explicit Desktop choice must have launch priority")
    try require(discovered.cliCommands.first?.path == native.path, "Explicit CLI choice must have launch priority")
    try require(discovered.nativeExecutables.contains(native.path) && discovered.nativeExecutables.contains(oldNative.path), "Multiple native versions must remain observable")
    try require(!discovered.nativeExecutables.contains(nvm.path), "Shell shim must not itself become a kill target")
    let identity = ProcessIdentity(pid: 100, uid: 501, started: "now", executable: oldNative.path)
    try require(ProcessInspector.isProtected(identity, settings: GuardianSettings(), uid: 501, installations: discovered), "Older discovered version must match alongside current version")
    let node = ProcessIdentity(pid: 101, uid: 501, started: "now", executable: "/opt/node/bin/node")
    try require(ProcessInspector.isProtected(node, settings: GuardianSettings(), uid: 501, arguments: ["node", "--no-warnings", script.path], installations: discovered), "Installed package metadata must recognize Node CLI independent of PATH")
    let child = ProcessIdentity(pid: 102, uid: 501, started: "now", executable: helper.path)
    try require(ProcessInspector.isProtected(child, settings: GuardianSettings(), uid: 501, installations: discovered), "Custom Desktop helper must match")
    let other = ProcessIdentity(pid: 103, uid: 502, started: "now", executable: native.path)
    try require(!ProcessInspector.isProtected(other, settings: GuardianSettings(), uid: 501, installations: discovered), "Other user remains excluded")
    return checks
}
