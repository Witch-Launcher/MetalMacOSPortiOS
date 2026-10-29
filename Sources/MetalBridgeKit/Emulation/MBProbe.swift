import Foundation

/// Objective-C entry point for host apps that are not Swift (the Witch
/// launcher dlopens the framework and calls MBProbe to verify every
/// emulation service on the device before a macOS-ported Metal mod starts).
@objc(MBProbe)
public final class MBProbe: NSObject {
    @objc public static let frameworkVersion: NSString = "0.1.0"

    /// Runs all emulation-service probes on the default device.
    /// Returns a newline-separated "PASS|FAIL name: detail" report.
    @objc public static func runAllServices() -> NSString {
        let results = ServiceProbes.run()
        let lines = results.map {
            "\($0.passed ? "PASS" : "FAIL") \($0.name): \($0.detail)"
        }
        return NSString(string: lines.joined(separator: "\n"))
    }
}
