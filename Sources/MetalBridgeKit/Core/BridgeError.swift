import Foundation

public enum BridgeError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case noMetalDevice
    case unsupported(String)
    case invalidArgument(String)
    case allocationFailed(String)
    case operationFailed(String)

    public var description: String {
        switch self {
        case .noMetalDevice:
            return "No Metal device is available."
        case let .unsupported(reason):
            return "Unsupported on iOS: \(reason)"
        case let .invalidArgument(reason):
            return "Invalid argument: \(reason)"
        case let .allocationFailed(reason):
            return "Allocation failed: \(reason)"
        case let .operationFailed(reason):
            return "Operation failed: \(reason)"
        }
    }

    public var errorDescription: String? {
        description
    }
}
