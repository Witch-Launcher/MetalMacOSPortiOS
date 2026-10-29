import Foundation
import Metal

/// How a macOS render-target barrier (`MTLBarrierScope.renderTargets` or the deprecated
/// `MTLRenderCommandEncoder.textureBarrier()`) is reproduced on iOS.
///
/// Verified facts (iOS 26.2 SDK headers + Metal Feature Set Tables):
/// - `MTLBarrierScope.renderTargets` is `API_UNAVAILABLE(ios)`.
/// - `MTLRenderCommandEncoder.memoryBarrierWithScope:afterStages:beforeStages:` exists on
///   iOS 16.0+, but the Metal Feature Set Tables footnote states that Apple GPU families
///   3 through 10 do not support memory barriers whose `after` stages include `.fragment`
///   or `.tile`, or that use the renderTargets scope.
/// - Apple GPUs are tile-based deferred renderers (TBDR). The universally correct
///   equivalent of a macOS render-target barrier is to split the render pass: end the
///   encoder and open a new pass with `loadAction.load`.
public enum BridgeRenderTargetBarrierResolution: Equatable {
    /// Split the current render pass: end the encoder and open a new pass whose color
    /// attachments use `loadAction.load`. Always correct on Apple GPUs.
    case splitRenderPass(note: String)
    /// iOS 16+ render-encoder memory barrier. Documented as unsupported on Apple GPU
    /// families 3-10 for the stage combinations macOS code uses, so callers must
    /// runtime-validate before relying on it.
    case memoryBarrier(note: String)
}

public struct BarrierAdapter {
    public init() {}

    /// Returns the reproduction strategy for a macOS render-target barrier.
    public func renderTargetBarrierResolution() -> BridgeRenderTargetBarrierResolution {
        .splitRenderPass(note: """
            Apple GPUs are TBDR renderers. The equivalent of MTLBarrierScope.renderTargets \
            is splitting the render pass: end the current encoder and open a new pass with \
            loadAction.load. The Metal Feature Set Tables state that Apple GPU families 3-10 \
            do not support memory barriers with .fragment/.tile after stages or the \
            renderTargets scope, so the iOS 16+ memoryBarrier API is not a faithful replacement.
            """)
    }

    /// Legacy macOS `textureBarrier()` maps to the same resolution.
    public func legacyTextureBarrierResolution() -> BridgeRenderTargetBarrierResolution {
        renderTargetBarrierResolution()
    }

    /// Optional diagnostic path: attempts the iOS 16+ render-encoder memory barrier with the
    /// exact arguments the macOS API implies. This may fail at runtime on Apple3-Apple10
    /// devices; the failure is reported, never swallowed.
    public func attemptiOS16MemoryBarrier(on encoder: MTLRenderCommandEncoder,
                                          scope: MTLBarrierScope = .textures,
                                          after: MTLRenderStages = .vertex,
                                          before: MTLRenderStages = .fragment) throws -> BridgeOperationResult {
        if #available(iOS 16.0, *) {
            encoder.memoryBarrier(scope: scope, after: after, before: before)
            return .partial("""
                memoryBarrier(scope: \(scope.rawValue), after: \(after.rawValue), before: \(before.rawValue)) encoded. \
                Per the Metal Feature Set Tables, Apple GPU families 3-10 do not support .fragment/.tile \
                after stages or the renderTargets scope; this call must be runtime-validated.
                """)
        }
        throw BridgeError.unsupported("Render-encoder memory barriers require iOS 16 or newer; use the split-render-pass resolution instead.")
    }
}
