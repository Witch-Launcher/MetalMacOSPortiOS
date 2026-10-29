import Foundation
import Metal

public struct SynchronizationAdapter {
    public init() {}

    public func didModifyRange(_ buffer: MTLBuffer, range: Range<Int>) throws -> BridgeOperationResult {
        guard range.lowerBound >= 0, range.upperBound <= buffer.length else {
            throw BridgeError.invalidArgument("Range \(range) exceeds buffer length \(buffer.length).")
        }

        switch buffer.storageMode {
        case .shared:
            return .noActionRequired("iOS shared buffers are CPU/GPU coherent. No explicit didModifyRange upload is required.")
        case .private:
            throw BridgeError.unsupported("didModifyRange is only meaningful for managed storage. Private buffers cannot be modified from the CPU.")
        case .memoryless:
            throw BridgeError.unsupported("Memoryless storage cannot be observed or synchronized by the CPU.")
        @unknown default:
            throw BridgeError.unsupported("Unknown storage mode.")
        }
    }

    public func synchronize(_ resource: MTLResource,
                            using encoder: MTLBlitCommandEncoder) throws -> BridgeOperationResult {
        switch resource.storageMode {
        case .shared:
            return .noActionRequired("iOS shared storage needs no blit synchronization; the CPU and GPU share the allocation.")
        case .private:
            throw BridgeError.unsupported("synchronizeResource is a managed-storage operation. Private resources are GPU-only on iOS.")
        case .memoryless:
            throw BridgeError.unsupported("Memoryless storage has no CPU-visible backing to synchronize.")
        @unknown default:
            throw BridgeError.unsupported("Unknown storage mode.")
        }
    }

    public func synchronize(texture: MTLTexture,
                            slice: Int,
                            level: Int,
                            using encoder: MTLBlitCommandEncoder) throws -> BridgeOperationResult {
        guard slice >= 0, slice < texture.arrayLength else {
            throw BridgeError.invalidArgument("Slice \(slice) is outside the texture array length \(texture.arrayLength).")
        }
        guard level >= 0, level < texture.mipmapLevelCount else {
            throw BridgeError.invalidArgument("Mip level \(level) is outside the texture level count \(texture.mipmapLevelCount).")
        }
        return try synchronize(texture, using: encoder)
    }
}
