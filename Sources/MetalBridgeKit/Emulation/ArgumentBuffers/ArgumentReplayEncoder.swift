import Foundation
import Metal

/// Emulates macOS tier-2 argument-buffer indirection on A9 devices.
///
/// macOS apps pack resources into argument buffers (`setArgumentBuffer` plus
/// `setTexture`/`setBuffer`/`setSamplerState`) and rely on tier-2 behaviors
/// (nested argument buffers, heap-resident argument buffers). A9 tops out at
/// argument buffers tier 1, and nested argument buffers are unavailable there.
///
/// The bridge reproduces the observable behavior instead: every binding the
/// app records is replayed as a direct binding on each command encoder. The
/// shader sees the same resources in the same slots, with no argument buffer
/// in GPU memory. Recorded commands replay in order, so a later binding to the
/// same slot overrides an earlier one, exactly as it would when encoding.
///
/// The recorded list is independent of Metal state: `clear()` starts a fresh
/// sequence. `encodeSetBytes` copies its payload, so replay does not depend on
/// the caller's memory lifetime.
public final class ArgumentReplayEncoder {
    /// Stage selector for render encoders (compute has one stage).
    public enum Stage {
        case vertex
        case fragment
    }

    private enum Command {
        case buffer(MTLBuffer?, offset: Int, index: Int)
        case texture(MTLTexture?, index: Int)
        case sampler(MTLSamplerState?, index: Int)
        case bytes(Data, index: Int)
    }

    private let lock = NSLock()
    private var commands: [Command] = []

    public init() {}

    /// Number of recorded commands (useful for diagnostics and tests).
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return commands.count
    }

    public func encodeSetBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int) {
        self.append(.buffer(buffer, offset: offset, index: index))
    }

    public func encodeSetTexture(_ texture: MTLTexture?, index: Int) {
        self.append(.texture(texture, index: index))
    }

    public func encodeSetSamplerState(_ sampler: MTLSamplerState?, index: Int) {
        self.append(.sampler(sampler, index: index))
    }

    /// Records a byte payload binding. The data is copied on record.
    public func encodeSetBytes(_ bytes: Data, index: Int) {
        self.append(.bytes(bytes, index: index))
    }

    /// Drops all recorded commands.
    public func clear() {
        lock.lock()
        commands.removeAll()
        lock.unlock()
    }

    /// Replays every recorded binding into a compute encoder.
    public func replay(into encoder: MTLComputeCommandEncoder) {
        lock.lock()
        let commands = self.commands
        lock.unlock()
        for command in commands {
            self.apply(command, compute: encoder, render: nil, stage: nil)
        }
    }

    /// Replays every recorded binding into one stage of a render encoder.
    public func replay(into encoder: MTLRenderCommandEncoder, at stage: Stage) {
        lock.lock()
        let commands = self.commands
        lock.unlock()
        for command in commands {
            self.apply(command, compute: nil, render: encoder, stage: stage)
        }
    }

    private func append(_ command: Command) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    private func apply(_ command: Command,
                       compute: MTLComputeCommandEncoder?,
                       render: MTLRenderCommandEncoder?,
                       stage: Stage?) {
        switch command {
        case let .buffer(buffer, offset, index):
            if compute != nil {
                compute?.setBuffer(buffer, offset: offset, index: index)
            } else {
                switch stage {
                case .vertex: render?.setVertexBuffer(buffer, offset: offset, index: index)
                case .fragment: render?.setFragmentBuffer(buffer, offset: offset, index: index)
                case nil: break
                }
            }
        case let .texture(texture, index):
            if compute != nil {
                compute?.setTexture(texture, index: index)
            } else {
                switch stage {
                case .vertex: render?.setVertexTexture(texture, index: index)
                case .fragment: render?.setFragmentTexture(texture, index: index)
                case nil: break
                }
            }
        case let .sampler(sampler, index):
            if compute != nil {
                compute?.setSamplerState(sampler, index: index)
            } else {
                switch stage {
                case .vertex: render?.setVertexSamplerState(sampler, index: index)
                case .fragment: render?.setFragmentSamplerState(sampler, index: index)
                case nil: break
                }
            }
        case let .bytes(data, index):
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                if compute != nil {
                    compute?.setBytes(base, length: raw.count, index: index)
                } else {
                    switch stage {
                    case .vertex: render?.setVertexBytes(base, length: raw.count, index: index)
                    case .fragment: render?.setFragmentBytes(base, length: raw.count, index: index)
                    case nil: break
                    }
                }
            }
        }
    }
}
