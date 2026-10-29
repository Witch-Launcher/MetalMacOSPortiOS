import Foundation
import Metal

public enum BridgePixelFormat: String, CaseIterable {
    case depth24UnormStencil8
    case x24Stencil8
    case depth32FloatStencil8
}

public struct PixelFormatAdapter {
    public init() {}

    public func resolve(_ requested: BridgePixelFormat) -> BridgeResult<MTLPixelFormat> {
        switch requested {
        case .depth24UnormStencil8:
            return .converted(.depth32Float_stencil8,
                              note: "iOS does not expose depth24Unorm_stencil8. depth32Float_stencil8 preserves depth and stencil roles with higher depth precision and a different memory footprint.")
        case .x24Stencil8:
            return .unsupported(reason: "iOS has no public X24 stencil-only pixel format.")
        case .depth32FloatStencil8:
            return .native(.depth32Float_stencil8)
        }
    }
}
