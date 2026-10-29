import Foundation
import Metal

public struct BridgeCapabilities {
    public let deviceName: String
    public let operatingSystem: String
    public let gpuFamilies: [String]
    public let familyNumbers: Set<Int>
    public let supportsA9Baseline: Bool
    public let supportsMSAA4: Bool
    public let supportsMetal3: Bool
    public let supportsMetal4: Bool
    public let supports32BitFloatFiltering: BridgeResult<Bool>
    public let supportsBCTextureCompression: BridgeResult<Bool>
    public let hasUnifiedMemory: BridgeResult<Bool>
    public let maxThreadsPerThreadgroup: String
    public let maxBufferLength: UInt64
    public let sampleCounts: [Int]
    public let probeMode: String

    /// Probes the runtime GPU capability of an iOS Apple GPU.
    ///
    /// Deployment target is iOS 14.0, so `supportsFamily` (iOS 13+) is always available.
    /// The legacy `supportsFeatureSet` path used for the previous iOS 12 floor has been
    /// removed; Apple documents MTLFeatureSet as deprecated in favor of MTLGPUFamily.
    public init(device: MTLDevice) {
        var families = Set<Int>()
        let candidates: [(MTLGPUFamily, Int)] = [
            (.apple1, 1), (.apple2, 2), (.apple3, 3), (.apple4, 4), (.apple5, 5),
            (.apple6, 6), (.apple7, 7), (.apple8, 8), (.apple9, 9), (.apple10, 10)
        ]
        for (family, number) in candidates where device.supportsFamily(family) {
            families.insert(number)
        }

        var samples = [1]
        for candidate in [2, 4, 8] where device.supportsTextureSampleCount(candidate) {
            samples.append(candidate)
        }

        let familyNames = families.sorted().map { "Apple\($0)" }
        let threads = device.maxThreadsPerThreadgroup

        self.deviceName = device.name
        self.operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        self.gpuFamilies = familyNames
        self.familyNumbers = families
        self.supportsA9Baseline = families.contains { $0 >= 3 }
        self.supportsMSAA4 = samples.contains(4)
        self.maxThreadsPerThreadgroup = "\(threads.width) x \(threads.height) x \(threads.depth)"
        self.maxBufferLength = UInt64(device.maxBufferLength)
        self.sampleCounts = samples
        self.probeMode = "supportsFamily"

        if #available(iOS 16.0, *) {
            self.supportsMetal3 = device.supportsFamily(.metal3)
        } else {
            self.supportsMetal3 = false
        }

        if #available(iOS 26.0, macOS 26.0, *) {
            self.supportsMetal4 = device.supportsFamily(.metal4)
        } else {
            self.supportsMetal4 = false
        }

        if #available(iOS 14.0, *) {
            self.supports32BitFloatFiltering = .native(device.supports32BitFloatFiltering)
        } else {
            self.supports32BitFloatFiltering = .unsupported(reason: "supports32BitFloatFiltering requires iOS 14 or newer.")
        }

        if #available(iOS 16.4, *) {
            self.supportsBCTextureCompression = .native(device.supportsBCTextureCompression)
        } else {
            self.supportsBCTextureCompression = .unsupported(reason: "supportsBCTextureCompression requires iOS 16.4 or newer.")
        }

        self.hasUnifiedMemory = .native(device.hasUnifiedMemory)
    }
}
