import Foundation
import Metal

public enum BridgeStorageMode: String, CaseIterable {
    case shared
    case managed
    case privateMode
    case memoryless

    public var title: String {
        switch self {
        case .shared: return "Shared"
        case .managed: return "Managed"
        case .privateMode: return "Private"
        case .memoryless: return "Memoryless"
        }
    }
}

public struct StorageModeAdapter {
    public init() {}

    public func resolve(_ requested: BridgeStorageMode) -> BridgeResult<MTLStorageMode> {
        switch requested {
        case .shared:
            return .native(.shared)
        case .managed:
            return .converted(.shared, note: "iOS has no managed storage. Shared storage provides CPU/GPU coherency without explicit synchronization.")
        case .privateMode:
            return .native(.private)
        case .memoryless:
            return .native(.memoryless)
        }
    }

    public func resourceOptions(for requested: BridgeStorageMode) -> BridgeResult<MTLResourceOptions> {
        switch requested {
        case .shared:
            return .native(.storageModeShared)
        case .managed:
            return .converted(.storageModeShared, note: "Managed storage is mapped to shared storage on iOS.")
        case .privateMode:
            return .native(.storageModePrivate)
        case .memoryless:
            return .native(.storageModeMemoryless)
        }
    }

    public func makeBuffer(device: MTLDevice, length: Int, mode: BridgeStorageMode) throws -> MTLBuffer {
        guard length > 0 else {
            throw BridgeError.invalidArgument("Buffer length must be greater than zero.")
        }
        guard mode != .memoryless else {
            throw BridgeError.unsupported("Memoryless storage is a texture-only on-chip mode on supported Apple GPUs. Buffers require shared or private storage.")
        }
        let resolution = resourceOptions(for: mode)
        guard let options = resolution.value else {
            throw BridgeError.unsupported(resolution.note ?? "The requested storage mode is unavailable.")
        }
        guard let buffer = device.makeBuffer(length: length, options: options) else {
            throw BridgeError.allocationFailed("makeBuffer(length: \(length), mode: \(mode.title)) returned nil.")
        }
        return buffer
    }

    public func makeTexture(device: MTLDevice,
                            width: Int,
                            height: Int,
                            pixelFormat: MTLPixelFormat,
                            usage: MTLTextureUsage,
                            mode: BridgeStorageMode) throws -> MTLTexture {
        guard width > 0, height > 0 else {
            throw BridgeError.invalidArgument("Texture dimensions must be greater than zero.")
        }
        let resolution = resolve(mode)
        guard let storageMode = resolution.value else {
            throw BridgeError.unsupported(resolution.note ?? "The requested storage mode is unavailable.")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = storageMode
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BridgeError.allocationFailed("makeTexture(\(width)x\(height), mode: \(mode.title)) returned nil.")
        }
        return texture
    }
}
