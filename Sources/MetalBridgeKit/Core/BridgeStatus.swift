import Foundation

public enum BridgeStatus: String, CaseIterable {
    case native
    case converted
    case partial
    case unsupported

    public var title: String {
        switch self {
        case .native: return "Native"
        case .converted: return "Converted"
        case .partial: return "Partial"
        case .unsupported: return "Unsupported"
        }
    }

    public var explanation: String {
        switch self {
        case .native:
            return "The public iOS Metal API is used directly."
        case .converted:
            return "The macOS behavior is translated to an iOS equivalent with a documented semantic difference."
        case .partial:
            return "Only part of the macOS behavior can be reproduced on iOS."
        case .unsupported:
            return "No valid public iOS implementation is available; the bridge reports this explicitly."
        }
    }
}
