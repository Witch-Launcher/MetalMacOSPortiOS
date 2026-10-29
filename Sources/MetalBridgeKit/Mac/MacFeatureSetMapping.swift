import Foundation
import Metal

/// macOS MTLFeatureSet values are not iOS capability identifiers: the constants are
/// `API_UNAVAILABLE(ios)` and their semantics describe macOS GPU hardware (Intel,
/// AMD, NVIDIA, and Apple-silicon Mac2). A macOS app that calls
/// `supportsFeatureSet(.macOS_GPUFamily1_v3)` cannot run that query on iOS, so the
/// bridge evaluates each macOS feature set as an explicit capability checklist
/// against the runtime iOS device.
///
/// The result is honest: `.native(true)` only when every checklist item is satisfied
/// on the runtime device; otherwise `.partial(false, ...)` naming exactly what is
/// missing. Nothing is reported as satisfied without a runtime or documented
/// family-level reason.
public enum BridgeMacFeatureSet: String, CaseIterable {
    case macOS_GPUFamily1_v1
    case macOS_GPUFamily1_v2
    case macOS_GPUFamily1_v3
    case macOS_GPUFamily1_v4
    case macOS_GPUFamily1_v5
    case macOS_GPUFamily2_v1
    case macOS_GPUFamily2_v2

    /// macOS availability of each feature set, per the macOS SDK MTLDevice.h.
    public var macOSAvailability: String {
        switch self {
        case .macOS_GPUFamily1_v1: return "10.11+"
        case .macOS_GPUFamily1_v2: return "10.13+"
        case .macOS_GPUFamily1_v3: return "10.14+"
        case .macOS_GPUFamily1_v4: return "10.15+"
        case .macOS_GPUFamily1_v5: return "11.0+"
        case .macOS_GPUFamily2_v1: return "11.0+ (Apple silicon)"
        case .macOS_GPUFamily2_v2: return "12.0+ (Apple silicon)"
        }
    }
}

/// One concrete capability a macOS feature set may require, evaluated on the
/// runtime iOS device. Each item carries its verification basis so the result can
/// be audited.
public struct MacCapabilityCheck {
    public let identifier: String
    public let satisfied: Bool
    public let basis: String

    public init(identifier: String, satisfied: Bool, basis: String) {
        self.identifier = identifier
        self.satisfied = satisfied
        self.basis = basis
    }
}

public struct MacFeatureSetMapping {
    public let device: MTLDevice
    public let capabilities: BridgeCapabilities

    public init(device: MTLDevice, capabilities: BridgeCapabilities) {
        self.device = device
        self.capabilities = capabilities
    }

    /// Runtime probes used across the checklists.
    public var runtimeChecks: [MacCapabilityCheck] {
        var checks: [MacCapabilityCheck] = []

        checks.append(MacCapabilityCheck(
            identifier: "compute",
            satisfied: capabilities.familyNumbers.contains { $0 >= 1 },
            basis: "Apple GPU family 1+ supports compute shaders (Metal Feature Set Tables)."))

        checks.append(MacCapabilityCheck(
            identifier: "memoryless",
            satisfied: capabilities.familyNumbers.contains { $0 >= 2 },
            basis: "Memoryless render targets require Apple GPU family 2+ (Metal Feature Set Tables)."))

        checks.append(MacCapabilityCheck(
            identifier: "resourceHeaps",
            satisfied: capabilities.familyNumbers.contains { $0 >= 2 },
            basis: "Resource heaps require Apple GPU family 2+ (Metal Feature Set Tables)."))

        checks.append(MacCapabilityCheck(
            identifier: "indirectDrawArguments",
            satisfied: capabilities.familyNumbers.contains { $0 >= 3 },
            basis: "Indirect draw and dispatch arguments require Apple GPU family 3+ (Metal Feature Set Tables)."))

        checks.append(MacCapabilityCheck(
            identifier: "msaa4",
            satisfied: device.supportsTextureSampleCount(4),
            basis: "Runtime probe: supportsTextureSampleCount(4)."))

        checks.append(MacCapabilityCheck(
            identifier: "msaa8",
            satisfied: device.supportsTextureSampleCount(8),
            basis: "Runtime probe: supportsTextureSampleCount(8). macOS GPU family 1 lists 8x MSAA; Apple GPUs top out at 4x."))

        let argumentTier = describe(device.argumentBuffersSupport)
        checks.append(MacCapabilityCheck(
            identifier: "argumentBuffersTier1",
            satisfied: argumentTier.contains("tier1") || argumentTier.contains("tier2"),
            basis: "Runtime probe: argumentBuffersSupport = \(argumentTier)."))

        checks.append(MacCapabilityCheck(
            identifier: "argumentBuffersTier2",
            satisfied: argumentTier.contains("tier2"),
            basis: "Runtime probe: argumentBuffersSupport = \(argumentTier). Tier 2 requires Apple GPU family 6+ (Metal Feature Set Tables)."))

        let readWriteTier = describe(device.readWriteTextureSupport)
        checks.append(MacCapabilityCheck(
            identifier: "readWriteTextures",
            satisfied: readWriteTier != "none",
            basis: "Runtime probe: readWriteTextureSupport = \(readWriteTier). Read/write textures require Apple GPU family 4+ (Metal Feature Set Tables)."))

        checks.append(MacCapabilityCheck(
            identifier: "fences",
            satisfied: capabilities.familyNumbers.contains { $0 >= 4 },
            basis: "Fences require Apple GPU family 4 (A11)+ (Metal Feature Set Tables). On iOS, fence updates are delayed to the end of the encoder and waits occur at the encoder start, per MTLRenderCommandEncoder.h."))

        checks.append(MacCapabilityCheck(
            identifier: "tessellationNative",
            satisfied: capabilities.supportsMetal3,
            basis: "Tessellation requires the Metal 3 programming model and Apple GPU family 3+ hardware (Metal Feature Set Tables). iOS 14/15 A9 devices use the bridge software tessellation path instead."))

        checks.append(MacCapabilityCheck(
            identifier: "bcSampling",
            satisfied: bcCompressionSupported,
            basis: "BC formats are iOS 16.4+ API and require supportsBCTextureCompression (Apple7/8 hardware per the Metal Feature Set Tables). A9 decodes BC textures through the bridge compute path."))

        checks.append(MacCapabilityCheck(
            identifier: "sparseTextures",
            satisfied: capabilities.familyNumbers.contains { $0 >= 6 },
            basis: "Sparse color textures with automatic heap backing require Apple GPU family 6+ (A13) (Metal Feature Set Tables). A9 uses the bridge resident-fallback path."))

        checks.append(MacCapabilityCheck(
            identifier: "depth24Stencil8",
            satisfied: false,
            basis: "MTLPixelFormat.depth24Unorm_stencil8 is macOS-only in the SDK. The bridge converts it to depth32Float_stencil8."))

        return checks
    }

    private var bcCompressionSupported: Bool {
        if #available(iOS 16.4, *) {
            return device.supportsBCTextureCompression
        }
        // iOS 14-16.3 cannot query the property; the Feature Set Tables require
        // Apple7/8 hardware, which an A9-class device cannot report. Treat as false.
        return false
    }

    private func describe(_ tier: MTLArgumentBuffersTier) -> String {
        switch tier {
        case .tier1: return "tier1"
        case .tier2: return "tier2"
        @unknown default: return "unknown(\(tier.rawValue))"
        }
    }

    private func describe(_ tier: MTLReadWriteTextureTier) -> String {
        switch tier {
        case .tierNone: return "none"
        case .tier1: return "tier1"
        case .tier2: return "tier2"
        @unknown default: return "unknown(\(tier.rawValue))"
        }
    }

    /// Evaluates one macOS feature set against the runtime device.
    ///
    /// Items that the referenced macOS feature set does not require are excluded,
    /// so the mapping is directional: a macOS minimum feature set can be satisfied
    /// by an iOS device that covers its concrete capability list, but Apple-silicon
    /// sets (mac2) that require tier-2 argument buffers or render-stage barriers
    /// cannot be satisfied by any current iOS device.
    public func evaluate(_ featureSet: BridgeMacFeatureSet) -> BridgeResult<Bool> {
        let required = requiredCapabilities(for: featureSet)
        let runtime = runtimeChecks
        let missing = runtime
            .filter { required.contains($0.identifier) && !$0.satisfied }
            .map { "\($0.identifier) (\($0.basis))" }

        if missing.isEmpty {
            return .partial(true, note: """
                All required capabilities of \(featureSet.rawValue) are satisfied on this device. \
                The value is a bridge evaluation, not Apple's macOS feature-set query: iOS \
                devices never report macOS feature sets natively.
                """)
        }
        return .partial(false, note: """
            \(featureSet.rawValue) is not satisfied. Missing on this device: \(missing.joined(separator: "; ")).
            """)
    }

    private func requiredCapabilities(for featureSet: BridgeMacFeatureSet) -> Set<String> {
        var required: Set<String> = ["compute", "memoryless", "resourceHeaps", "indirectDrawArguments", "msaa4"]
        switch featureSet {
        case .macOS_GPUFamily1_v1, .macOS_GPUFamily1_v2:
            break
        case .macOS_GPUFamily1_v3, .macOS_GPUFamily1_v4:
            required.formUnion(["argumentBuffersTier1", "tessellationNative"])
        case .macOS_GPUFamily1_v5:
            required.formUnion(["argumentBuffersTier1", "tessellationNative", "readWriteTextures"])
        case .macOS_GPUFamily2_v1, .macOS_GPUFamily2_v2:
            required.formUnion(["argumentBuffersTier2", "tessellationNative", "readWriteTextures", "sparseTextures"])
        }
        return required
    }
}
