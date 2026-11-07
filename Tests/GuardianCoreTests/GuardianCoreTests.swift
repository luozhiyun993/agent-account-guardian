import XCTest
@testable import GuardianCore
import Darwin

final class GuardianPolicyTests: XCTestCase {
    private let healthy = LocalHealth.healthy(interface: "utun1500")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func exit(_ ip: String = "8.8.8.8", _ country: String = "JP") -> ExitHealth {
        .known(ExitObservation(ip: ip, country: country, timestamp: now))
    }

    func testMatchingCountryAllowsLaunchAndIPChangeOnlyWarns() {
        let settings = GuardianSettings()
        XCTAssertEqual(GuardianPolicy.evaluate(settings: settings, local: healthy, exit: exit(), now: now), .allow)
        let changed = GuardianPolicy.evaluate(settings: settings, local: healthy, exit: exit(), previousIP: "1.1.1.1", now: now)
        guard case .warn = changed else { return XCTFail("Same-country changes must only warn") }
        XCTAssertTrue(changed.mayLaunch)
    }

    func testWrongCountryTrips() {
        let result = GuardianPolicy.evaluate(settings: GuardianSettings(), local: healthy, exit: exit("8.8.8.8", "US"), now: now)
        guard case .trip = result else { return XCTFail("Country mismatch must trip") }
        XCTAssertFalse(result.mayLaunch)
    }

    func testPinnedMismatchTripsWithinSameCountry() {
        var settings = GuardianSettings()
        settings.pinEnabled = true
        settings.pinnedIP = "1.1.1.1"
        guard case .trip = GuardianPolicy.evaluate(settings: settings, local: healthy, exit: exit(), now: now) else {
            return XCTFail("Pinned IP must match even within target country")
        }
    }

    func testPinnedMatchDoesNotOverrideWrongCountry() {
        var settings = GuardianSettings()
        settings.pinEnabled = true
        settings.pinnedIP = "8.8.8.8"
        guard case .trip = GuardianPolicy.evaluate(settings: settings, local: healthy, exit: exit("8.8.8.8", "US"), now: now) else {
            return XCTFail("Pinning adds a constraint; it does not bypass country checks")
        }
    }

    func testTimeoutDoesNotTripButBlocksLaunch() {
        let result = GuardianPolicy.evaluate(settings: GuardianSettings(), local: healthy, exit: .unknown("timeout"), now: now)
        XCTAssertEqual(result, .wait("timeout"))
        var state = ProtectionState()
        state.enabled = true
        state.observe(result)
        XCTAssertNil(state.lockedReason)
        XCTAssertFalse(result.mayLaunch)
    }

    func testConfirmedKernelFailureTripsEvenWhenNetworkIsUnknown() {
        let result = GuardianPolicy.evaluate(settings: GuardianSettings(), local: .unsafe("kernel stopped"), exit: .unknown("timeout"), now: now)
        XCTAssertEqual(result, .trip("kernel stopped"))
    }

    func testUnknownLocalDoesNotHideConfirmedExitMismatch() {
        let result = GuardianPolicy.evaluate(settings: GuardianSettings(), local: .unknown("route unavailable"), exit: exit("8.8.8.8", "US"), now: now)
        guard case .trip = result else { return XCTFail("Confirmed exit violation must trip") }
    }

    func testStaleOrFutureObservationCannotLaunch() {
        for timestamp in [now.addingTimeInterval(-26), now.addingTimeInterval(10)] {
            let result = GuardianPolicy.evaluate(settings: GuardianSettings(), local: healthy,
                exit: .known(ExitObservation(ip: "8.8.8.8", country: "JP", timestamp: timestamp)), now: now)
            guard case .wait = result else { return XCTFail("Unusable observations cannot authorize launch") }
        }
    }

    func testObservationModeDoesNotLockOrAllowLaunch() {
        var state = ProtectionState()
        state.heartbeat = now
        state.observe(.trip("wrong country"))
        XCTAssertNil(state.lockedReason)
        XCTAssertFalse(state.permitsLaunch(.allow, now: now))
    }

    func testRecoveryRequiresManualSuccessfulCheckAndEnabledProtection() {
        var state = ProtectionState()
        state.enabled = true
        state.heartbeat = now
        state.observe(.trip("wrong country"))
        state.observe(.allow)
        XCTAssertEqual(state.lockedReason, "wrong country")
        XCTAssertFalse(state.permitsLaunch(.allow, now: now))
        XCTAssertFalse(state.recover(.wait("timeout")))
        state.enabled = false
        XCTAssertFalse(state.recover(.allow))
        state.enabled = true
        XCTAssertTrue(state.recover(.allow))
        XCTAssertTrue(state.permitsLaunch(.allow, now: now))
        XCTAssertFalse(state.permitsLaunch(.allow, now: now.addingTimeInterval(9)))
    }

    func testIPv6CanonicalEquality() {
        var settings = GuardianSettings()
        settings.pinEnabled = true
        settings.pinnedIP = "2606:4700:4700:0000:0000:0000:0000:1111"
        XCTAssertEqual(GuardianPolicy.evaluate(settings: settings, local: healthy,
            exit: exit("2606:4700:4700::1111"), now: now), .allow)
    }

    func testTraceRejectsMalformedDuplicateAndUnknownData() {
        for text in ["<html>blocked</html>", "ip=8.8.8.8\nloc=XX", "ip=127.0.0.1\nloc=JP",
                     "ip=8.8.8.8\nloc=JP\nloc=US", "ip=abc\nloc=JP", "ip=8.8.8.8"] {
            XCTAssertNil(ExitObservation.parse(text))
        }
        XCTAssertEqual(ExitObservation.parse("fl=test\nip=8.8.8.8\nloc=JP\n", now: now)?.country, "JP")
    }

    func testInvalidSettingsBlock() {
        var settings = GuardianSettings()
        settings.country = "Japan"
        XCTAssertNotNil(settings.validationError)
        settings.country = "JP"
        settings.pinEnabled = true
        for value in ["", "127.0.0.1", "198.18.0.1", "10.0.0.1", "1.1.1.1:7890", "::1"] {
            settings.pinnedIP = value
            XCTAssertNotNil(settings.validationError)
        }
    }

    func testLockAndSettingsPersistAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(directory: directory)
        var state = ProtectionState()
        state.enabled = true
        state.settings.pinEnabled = true
        state.settings.pinnedIP = "1.1.1.1"
        state.observe(.trip("pinned mismatch"))
        try store.save(state)
        let restored = try store.load()
        XCTAssertEqual(restored.lockedReason, "pinned mismatch")
        XCTAssertEqual(restored.settings, state.settings)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

final class InspectionTests: XCTestCase {
    func testConfigParserUsesTunScopeNotDNSOrOtherEnableFields() {
        let yaml = "mixed-port: 7890\ntun:\n  enable: true\n  device: utun1500\ndns:\n  enable: false\n  device: utun9\n"
        let result = LocalInspector.tunDevice(from: yaml)
        XCTAssertEqual(result.enabled, true)
        XCTAssertEqual(result.device, "utun1500")
        XCTAssertNil(LocalInspector.tunDevice(from: "tun:\n  enable: true\n  device: ';bad'\n").device)
    }

    func testProcessParserPreservesSpacesAndStartIdentity() {
        let result = ProcessIdentity.parse("  421 501 Sat Nov  7 21:00:00 2026     /Applications/Clash Party.app/Contents/Resources/sidecar/mihomo")
        XCTAssertEqual(result?.pid, 421)
        XCTAssertEqual(result?.started, "Sat Nov 7 21:00:00 2026")
        XCTAssertEqual(result?.executable, "/Applications/Clash Party.app/Contents/Resources/sidecar/mihomo")
    }

    func testMatcherDoesNotSelectOtherUsersOrSimilarNames() {
        let settings = GuardianSettings()
        func process(_ path: String, uid: UInt32 = 501) -> ProcessIdentity {
            ProcessIdentity(pid: 100, uid: uid, started: "today", executable: path)
        }
        XCTAssertTrue(ProcessInspector.isProtected(process("/Applications/Claude.app/Contents/MacOS/Claude"), settings: settings, uid: 501))
        XCTAssertFalse(ProcessInspector.isProtected(process("/Applications/Claude.app/Contents/MacOS/Claude", uid: 502), settings: settings, uid: 501))
        XCTAssertFalse(ProcessInspector.isProtected(process("/tmp/Claude.app/Contents/MacOS/Claude"), settings: settings, uid: 501))
        XCTAssertFalse(ProcessInspector.isProtected(process("/Applications/Claude.app.fake/Contents/MacOS/Claude"), settings: settings, uid: 501))
        XCTAssertFalse(ProcessInspector.isProtected(process("/usr/local/bin/claude-helper"), settings: settings, uid: 501, cliExecutable: "/usr/local/bin/claude"))
    }

    func testNodeMatchingRequiresActualEntrypointNotMentionInEval() {
        let path = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        let identity = ProcessIdentity(pid: 100, uid: 501, started: "today", executable: "/opt/homebrew/bin/node")
        XCTAssertTrue(ProcessInspector.isProtected(identity, settings: GuardianSettings(), uid: 501, cliExecutable: path, arguments: ["node", path]))
        XCTAssertFalse(ProcessInspector.isProtected(identity, settings: GuardianSettings(), uid: 501, cliExecutable: path, arguments: ["node", "-e", path]))
    }

    func testStopperTerminatesOnlyOwnedDisposableChild() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        guard let target = ProcessInspector.snapshot()?.first(where: { $0.pid == child.processIdentifier }) else {
            throw XCTSkip("Process inspection unavailable in this environment")
        }
        let stale = ProcessIdentity(pid: target.pid, uid: target.uid, started: "different start", executable: target.executable)
        let rejected = await ProcessStopper.stop([stale])
        XCTAssertEqual(rejected.stopped, 0)
        XCTAssertTrue(child.isRunning)
        let report = await ProcessStopper.stop([target])
        child.waitUntilExit()
        XCTAssertEqual(report.stopped, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertFalse(child.isRunning)
    }
}
