import Foundation

public enum BridgeUnsupportedCapability: String, CaseIterable {
    case macOSFeatureSets
    case sparseHeaps
    case deviceRemovalErrors

    public var title: String {
        switch self {
        case .macOSFeatureSets:
            return "macOS feature sets"
        case .sparseHeaps:
            return "Sparse heaps"
        case .deviceRemovalErrors:
            return "Device-removal errors"
        }
    }

    public var reason: String {
        switch self {
        case .macOSFeatureSets:
            return "MTLFeatureSet macOS GPU-family values are not iOS capability identifiers."
        case .sparseHeaps:
            return "MTLHeapType.sparse is not exposed to iOS apps."
        case .deviceRemovalErrors:
            return "iOS has no public MTLCommandBufferError.deviceRemoved path."
        }
    }
}

public struct PlatformLimitationAdapter {
    public init() {}

    public func isSupported(_ capability: BridgeUnsupportedCapability) -> BridgeResult<Bool> {
        .unsupported(reason: capability.reason)
    }
}
