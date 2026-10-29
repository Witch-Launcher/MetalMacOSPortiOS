import Foundation

public enum BridgeResult<Value> {
    case native(Value)
    case converted(Value, note: String)
    case partial(Value, note: String)
    case unsupported(reason: String)

    public var status: BridgeStatus {
        switch self {
        case .native: return .native
        case .converted: return .converted
        case .partial: return .partial
        case .unsupported: return .unsupported
        }
    }

    public var value: Value? {
        switch self {
        case let .native(value): return value
        case let .converted(value, _): return value
        case let .partial(value, _): return value
        case .unsupported: return nil
        }
    }

    public var note: String? {
        switch self {
        case .native: return nil
        case let .converted(_, note): return note
        case let .partial(_, note): return note
        case let .unsupported(reason): return reason
        }
    }
}

public enum BridgeOperationResult: Equatable {
    case performed(String)
    case noActionRequired(String)
    case partial(String)

    public var explanation: String {
        switch self {
        case let .performed(text): return text
        case let .noActionRequired(text): return text
        case let .partial(text): return text
        }
    }
}
