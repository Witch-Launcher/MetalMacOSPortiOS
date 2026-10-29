import Foundation
import Metal

public final class MetalBridge {
    public let device: MTLDevice
    public let capabilities: BridgeCapabilities
    public let deviceAdapter: DeviceAdapter
    public let topology: DeviceTopologyAdapter
    public let storage: StorageModeAdapter
    public let pixelFormats: PixelFormatAdapter
    public let synchronization: SynchronizationAdapter
    public let barriers: BarrierAdapter
    public let remoteResources: RemoteResourceAdapter
    public let platformLimitations: PlatformLimitationAdapter

    public init(device: MTLDevice? = nil) throws {
        guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
            throw BridgeError.noMetalDevice
        }
        self.device = resolved
        self.capabilities = BridgeCapabilities(device: resolved)
        self.deviceAdapter = DeviceAdapter(device: resolved)
        self.topology = DeviceTopologyAdapter(device: resolved)
        self.storage = StorageModeAdapter()
        self.pixelFormats = PixelFormatAdapter()
        self.synchronization = SynchronizationAdapter()
        self.barriers = BarrierAdapter()
        self.remoteResources = RemoteResourceAdapter()
        self.platformLimitations = PlatformLimitationAdapter()
    }

    public func makeBuffer(length: Int, mode: BridgeStorageMode) throws -> MTLBuffer {
        try storage.makeBuffer(device: device, length: length, mode: mode)
    }

    public func makeTexture(width: Int,
                            height: Int,
                            pixelFormat: MTLPixelFormat,
                            usage: MTLTextureUsage,
                            mode: BridgeStorageMode) throws -> MTLTexture {
        try storage.makeTexture(device: device,
                                width: width,
                                height: height,
                                pixelFormat: pixelFormat,
                                usage: usage,
                                mode: mode)
    }

    public func makeCommandQueue() throws -> MTLCommandQueue {
        guard let queue = device.makeCommandQueue() else {
            throw BridgeError.operationFailed("MTLDevice.makeCommandQueue returned nil.")
        }
        return queue
    }
}
