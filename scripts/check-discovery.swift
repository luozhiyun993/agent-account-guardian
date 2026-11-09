import Foundation

@main struct DiscoveryCheckRunner {
    static func main() throws {
        let count = try discoveryRegressionChecks()
        print("PASS: \(count) installation-discovery regression checks. No Claude process was launched or terminated.")
    }
}
