import Foundation
import Metal

/// Reference implementation limits for macOS GPU families, taken from Apple's Metal
/// Feature Set Tables (Implementation Limits, macOS GPU family 1 and Mac2/Apple silicon).
/// These are informational targets the bridge compares against; the runtime device
/// values below are the source of truth for what the bridge can actually do.
public struct MacReferenceLimits {
    /// macOS GPU family 1: maxBufferLength is 4 GB. Apple silicon (Mac2) reports the
    /// same order of magnitude; an A9 device cannot.
    public static let maxBufferLength: UInt64 = 4 * 1024 * 1024 * 1024
    /// macOS GPU family 1: 32 KB of threadgroup memory.
    public static let maxThreadgroupMemoryLength: Int = 32 * 1024
    /// macOS GPU family 1: 1024 threads per threadgroup.
    public static let maxThreadsPerThreadgroupWidth: Int = 1024
    /// macOS GPU family 1 supports up to 8x MSAA on discrete GPUs; Apple GPUs support 4x.
    public static let maxMSAASampleCount: Int = 8
    /// Maximum tessellation factor on macOS is 64; Apple family 3 hardware is 16 and
    /// family 4+ is 64 (Metal Feature Set Tables, Maximum tessellation factor row).
    public static let maxTessellationFactor: Int = 64
    /// macOS GPU family 1: 16384 texels for 2D textures.
    public static let maxTexture2DDimension: Int = 16384
}

/// Runtime implementation limits of the iOS device the bridge is running on,
/// plus the guard helpers macOS ports need so a Mac-tuned allocation fails with a
/// clear message instead of a silent Metal error.
public struct BridgeLimitProfile {
    public let device: MTLDevice

    // Runtime probed values.
    public let maxBufferLength: UInt64
    public let maxThreadgroupMemoryLength: Int
    public let maxThreadsPerThreadgroup: MTLSize
    public let supportedSampleCounts: [Int]
    public let argumentBuffersTier: String
    public let readWriteTextureTier: String

    // Family-based values (Metal Feature Set Tables; no per-device public query on iOS).
    public let maxTessellationFactor: Int
    public let maxTexture2DDimension: Int
    public let memorylessSupported: Bool
    public let indirectDrawArguments: Bool
    public let fencesNative: Bool
    public let nativeTessellation: Bool

    public init(device: MTLDevice, capabilities: BridgeCapabilities) {
        self.device = device
        self.maxBufferLength = UInt64(device.maxBufferLength)
        self.maxThreadgroupMemoryLength = device.maxThreadgroupMemoryLength
        self.maxThreadsPerThreadgroup = device.maxThreadsPerThreadgroup

        var samples = [1]
        for count in [2, 4, 8] where device.supportsTextureSampleCount(count) {
            samples.append(count)
        }
        self.supportedSampleCounts = samples

        switch device.argumentBuffersSupport {
        case .tier1: self.argumentBuffersTier = "tier1"
        case .tier2: self.argumentBuffersTier = "tier2"
        @unknown default: self.argumentBuffersTier = "unknown"
        }

        switch device.readWriteTextureSupport {
        case .tierNone: self.readWriteTextureTier = "none"
        case .tier1: self.readWriteTextureTier = "tier1"
        case .tier2: self.readWriteTextureTier = "tier2"
        @unknown default: self.readWriteTextureTier = "unknown"
        }

        let topFamily = capabilities.familyNumbers.max() ?? 0
        // Metal Feature Set Tables, "Maximum tessellation factor": Apple1 n/a,
        // Apple2/3 = 16, Apple4+ = 64. The bridge tessellator clamps to this value.
        self.maxTessellationFactor = topFamily >= 4 ? 64 : 16
        // Metal Feature Set Tables, texture limits: Apple1/2 = 8192, Apple3+ = 16384.
        self.maxTexture2DDimension = topFamily >= 3 ? 16384 : 8192
        self.memorylessSupported = topFamily >= 2
        self.indirectDrawArguments = topFamily >= 3
        self.fencesNative = topFamily >= 4
        self.nativeTessellation = capabilities.supportsMetal3
    }

    /// Guards a macOS-tuned buffer allocation against the A9-class limit.
    public func validateBufferLength(_ length: Int) throws {
        guard length > 0 else {
            throw BridgeError.invalidArgument("Buffer length must be greater than zero.")
        }
        guard UInt64(length) <= maxBufferLength else {
            throw BridgeError.allocationFailed("""
                Requested buffer length \(length) exceeds this device's maxBufferLength \
                (\(maxBufferLength)). A macOS build may assume the macOS limit of \
                \(MacReferenceLimits.maxBufferLength). Split the buffer or lower the allocation.
                """)
        }
    }

    /// Guards a sample count request against the Apple GPU MSAA limit.
    public func validateSampleCount(_ count: Int) throws {
        guard supportedSampleCounts.contains(count) else {
            throw BridgeError.unsupported("""
                Sample count \(count) is not supported on this device (supported: \
                \(supportedSampleCounts.map(String.init).joined(separator: ", "))). \
                macOS GPU family 1 supports up to \(MacReferenceLimits.maxMSAASampleCount)x MSAA; \
                Apple GPUs support up to 4x. The bridge MSAA policy downlevels larger counts to 4x.
                """)
        }
    }

    /// Clamps a requested tessellation factor to the family maximum.
    public func clampTessellationFactor(_ factor: Float) -> (value: Float, clamped: Bool) {
        let maximum = Float(maxTessellationFactor)
        if factor > maximum {
            return (maximum, true)
        }
        return (factor, false)
    }

    public var summary: [(String, String)] {
        [
            ("maxBufferLength", "\(maxBufferLength) (macOS reference: \(MacReferenceLimits.maxBufferLength))"),
            ("maxThreadgroupMemoryLength", "\(maxThreadgroupMemoryLength)"),
            ("maxThreadsPerThreadgroup", "\(maxThreadsPerThreadgroup.width) x \(maxThreadsPerThreadgroup.height) x \(maxThreadsPerThreadgroup.depth)"),
            ("MSAA sample counts", supportedSampleCounts.map(String.init).joined(separator: ", ")),
            ("maxTessellationFactor", "\(maxTessellationFactor) (macOS: \(MacReferenceLimits.maxTessellationFactor))"),
            ("maxTexture2DDimension", "\(maxTexture2DDimension)"),
            ("argumentBuffersTier", argumentBuffersTier),
            ("readWriteTextureTier", readWriteTextureTier),
            ("memoryless", memorylessSupported ? "Yes" : "No"),
            ("indirectDrawArguments", indirectDrawArguments ? "Yes" : "No"),
            ("fencesNative", fencesNative ? "Yes" : "No (bridge event path)"),
            ("nativeTessellation", nativeTessellation ? "Yes (Metal 3)" : "No (bridge software path)")
        ]
    }
}
