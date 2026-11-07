import XCTest
import Network
@testable import GuardianCore

final class NetworkInspectionTests: XCTestCase {
    private let endpoint = ProxyEndpoint(host: "127.0.0.1", port: 7890)!
    private var proxySettings: [String: Any] {
        ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890]
    }

    func testTunnelDetectionUsesRoutesWithoutClientIdentity() {
        for interface in ["utun7", "utun1500", "tun0", "ppp0", "ipsec3", "wg1"] {
            let result = LocalInspector.evaluate(proxy: .none, routes: [interface, interface],
                interfaces: [interface, "en0"], reachability: { _ in XCTFail(); return .unavailable })
            XCTAssertEqual(result.transport, .tunnel([interface]))
            guard case .healthy = result.health else { return XCTFail("Tunnel should be recognized") }
        }
        XCTAssertFalse(LocalInspector.isTunnel("utun7; command"))
    }

    func testUnrelatedTunnelDoesNotHideDirectOrPartialRoutes() {
        for routes in [["en0", "en0"], ["utun7", "en0"]] {
            let result = LocalInspector.evaluate(proxy: .none, routes: routes, interfaces: ["utun7", "en0"],
                reachability: { _ in .reachable })
            guard case .unsafe = result.health else { return XCTFail("Direct route must trip") }
            XCTAssertNil(result.transport)
        }
    }

    func testMissingOrChangingRoutesRemainUnknown() {
        for routes: [String?] in [[nil, nil], ["utun7", nil], ["utun99", "utun99"], []] {
            let result = LocalInspector.evaluate(proxy: .none, routes: routes, interfaces: ["utun7"],
                reachability: { _ in .reachable })
            guard case .unknown = result.health else { return XCTFail("Unavailable routes must wait") }
        }
    }

    func testStaticHTTPSNeedsNoTunnelAndDistinguishesRefusalFromTimeout() {
        let reachable = LocalInspector.evaluate(proxy: .https(endpoint), routes: [], interfaces: nil,
            reachability: { _ in .reachable })
        XCTAssertEqual(reachable.transport, .systemHTTPS(endpoint))
        let refused = LocalInspector.evaluate(proxy: .https(endpoint), routes: [], interfaces: nil,
            reachability: { _ in .refused })
        guard case .unsafe = refused.health else { return XCTFail("Refusal must trip") }
        let timeout = LocalInspector.evaluate(proxy: .https(endpoint), routes: [], interfaces: nil,
            reachability: { _ in .unavailable })
        guard case .unknown = timeout.health else { return XCTFail("Timeout must wait") }
    }

    func testSystemProxyParserAcceptsStaticHTTPSAndRejectsAmbiguousModes() {
        XCTAssertEqual(SystemProxyParser.parse([:]), .none)
        XCTAssertEqual(SystemProxyParser.parse(proxySettings), .https(endpoint))
        for settings: [String: Any] in [["ProxyAutoConfigEnable": 1], ["ProxyAutoDiscoveryEnable": 1],
            ["SOCKSEnable": 1], ["HTTPEnable": 1], ["HTTPSEnable": 1, "HTTPSPort": 0]] {
            guard case .unsupported = SystemProxyParser.parse(settings) else { return XCTFail("Must not authorize ambiguous proxy") }
        }
    }

    func testScopedProxyMustAgreeWithGlobalConfiguration() {
        var settings = proxySettings
        settings["__SCOPED__"] = ["en0": proxySettings]
        XCTAssertEqual(SystemProxyParser.parse(settings), .https(endpoint))
        settings["__SCOPED__"] = ["en0": ["HTTPSEnable": 0]]
        guard case .unsupported = SystemProxyParser.parse(settings) else { return XCTFail("Scoped direct path must not pass") }
    }

    func testProtectedDomainBypassRulesBlockAuthorization() {
        for exception in ["*.anthropic.com", ".claude.ai", "www.cloudflare.com", "*", "10.0.0.0/8"] {
            var settings = proxySettings
            settings["ExceptionsList"] = [exception]
            guard case .unsupported = SystemProxyParser.parse(settings) else { return XCTFail("Unsafe exception: \(exception)") }
        }
        var settings = proxySettings
        settings["ExceptionsList"] = ["<local>", "*.local", "example.org"]
        XCTAssertEqual(SystemProxyParser.parse(settings), .https(endpoint))
    }

    func testProbeConfigurationAndCLIUseSelectedProxy() {
        let transport = NetworkTransport.systemHTTPS(endpoint)
        let configuration = ExitInspector.configuration(transport: transport)
        XCTAssertEqual(configuration.connectionProxyDictionary?["HTTPSProxy"] as? String, endpoint.host)
        XCTAssertEqual(configuration.connectionProxyDictionary?["HTTPSPort"] as? Int, endpoint.port)
        XCTAssertEqual(configuration.connectionProxyDictionary?["ProxyAutoConfigEnable"] as? Int, 0)
        let environment = ["PATH": "/usr/bin", "HTTPS_PROXY": "http://old:123", "ALL_PROXY": "socks5://old:123", "no_proxy": "*"]
        let proxyEnvironment = transport.cliEnvironment(from: environment)
        XCTAssertEqual(proxyEnvironment["HTTPS_PROXY"], endpoint.url)
        XCTAssertEqual(proxyEnvironment["https_proxy"], endpoint.url)
        XCTAssertNil(proxyEnvironment["ALL_PROXY"])
        XCTAssertNil(proxyEnvironment["no_proxy"])
        let tunnel = NetworkTransport.tunnel(["utun7"])
        XCTAssertEqual(tunnel.cliEnvironment(from: environment), ["PATH": "/usr/bin"])
        XCTAssertEqual(tunnel.proxyDictionary["HTTPSEnable"] as? Int, 0)
    }

    func testEndpointValidationAndIPv6URL() {
        XCTAssertEqual(ProxyEndpoint(host: "[::1]", port: 8080)?.url, "http://[::1]:8080")
        XCTAssertNil(ProxyEndpoint(host: "http://localhost", port: 8080))
        XCTAssertNil(ProxyEndpoint(host: "localhost", port: 65536))
        XCTAssertNil(ProxyEndpoint(host: "user:password@localhost", port: 8080))
    }

    func testProxyChangesRequireRestartButTunnelRenumberingDoesNot() {
        let proxy = NetworkTransport.systemHTTPS(endpoint)
        let tunnel = NetworkTransport.tunnel(["utun7"])
        XCTAssertFalse(proxy.requiresProcessRestart(after: proxy))
        XCTAssertTrue(proxy.requiresProcessRestart(after: tunnel))
        XCTAssertTrue(tunnel.requiresProcessRestart(after: proxy))
        XCTAssertTrue(NetworkTransport.systemHTTPS(ProxyEndpoint(host: "localhost", port: 7891)!).requiresProcessRestart(after: proxy))
        XCTAssertFalse(NetworkTransport.tunnel(["utun8"]).requiresProcessRestart(after: tunnel))
    }

    func testExitProbeActuallyUsesProxyAndDoesNotFallbackAfterRejection() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "Proxy listening")
        let requested = expectation(description: "HTTPS CONNECT received")
        requested.assertForOverFulfill = false
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if let data, !data.isEmpty {
                    XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("CONNECT www.cloudflare.com:443"))
                    requested.fulfill()
                }
                connection.send(content: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port)
        let proxy = try XCTUnwrap(ProxyEndpoint(host: "127.0.0.1", port: Int(port.rawValue)))
        XCTAssertEqual(LocalInspector.checkEndpoint(proxy), .reachable)
        let result = await ExitInspector.inspect(transport: .systemHTTPS(proxy))
        await fulfillment(of: [requested], timeout: 3)
        guard case .unknown = result else { return XCTFail("Rejected proxy must not return direct exit success") }
    }
}
