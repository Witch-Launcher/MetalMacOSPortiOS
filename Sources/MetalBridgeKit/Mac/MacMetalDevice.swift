import Foundation
import Metal

/// A macOS-shaped Metal device facade on iOS.
///
/// This is the object a macOS Metal app talks to after recompiling its CPU code for
/// iOS. It reproduces the macOS Metal behavior surface:
/// - macOS-only device properties through the existing adapters (37 compatibility records).
/// - macOS feature-set queries through `MacFeatureSetMapping` (checklist evaluation).
/// - macOS implementation limits through `BridgeLimitProfile`, with explicit guards.
/// - Storage-mode conversion, synchronization, and barrier resolution through the adapters.
///
/// GPU-behavior emulation (tessellation, BC decode, MSAA downlevel, sparse fallback,
/// argument-buffer replay, fence events) plugs in through the `Emulation/` services.
public final class MacMetalDevice {
    public let device: MTLDevice
    public let capabilities: BridgeCapabilities
    public let limits: BridgeLimitProfile
    public let featureSets: MacFeatureSetMapping
    public let deviceAdapter: DeviceAdapter
    public let topology: DeviceTopologyAdapter
    public let storage: StorageModeAdapter
    public let pixelFormats: PixelFormatAdapter
    public let synchronization: SynchronizationAdapter
    public let barriers: BarrierAdapter
    public let remoteResources: RemoteResourceAdapter
    public let platformLimitations: PlatformLimitationAdapter
    /// Tessellation emulation (Phase 2). On Metal 3 devices the retarget tool prefers
    /// the native path; this service always works and is the A9 fallback.
    public private(set) var tessellation: TessellationEmulator!
    /// BC-compressed texture decoding (Phase 2). Apple GPUs below Apple7 cannot sample
    /// BC formats; this decodes them into samplable RGBA textures with bcdec-exact kernels.
    public private(set) var bcDecode: BCDecoder!
    /// Sparse-texture emulation (Phase 2): page-tracked dense fallbacks.
    public private(set) var sparse: SparseFallback!
    /// Shared-event fences (Phase 2): macOS listener semantics on CPU.
    public let fences: FenceBridge

    public init(device: MTLDevice? = nil) throws {
        guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
            throw BridgeError.noMetalDevice
        }
        self.device = resolved
        self.capabilities = BridgeCapabilities(device: resolved)
        self.limits = BridgeLimitProfile(device: resolved, capabilities: self.capabilities)
        self.featureSets = MacFeatureSetMapping(device: resolved, capabilities: self.capabilities)
        self.deviceAdapter = DeviceAdapter(device: resolved)
        self.topology = DeviceTopologyAdapter(device: resolved)
        self.storage = StorageModeAdapter()
        self.pixelFormats = PixelFormatAdapter()
        self.synchronization = SynchronizationAdapter()
        self.barriers = BarrierAdapter()
        self.remoteResources = RemoteResourceAdapter()
        self.platformLimitations = PlatformLimitationAdapter()
        self.tessellation = TessellationEmulator(device: resolved,
                                                 capabilities: self.capabilities,
                                                 maxTessellationFactor: self.limits.maxTessellationFactor)
        self.bcDecode = BCDecoder(device: resolved)
        self.sparse = SparseFallback(device: resolved)
        self.fences = FenceBridge(device: resolved)
    }

    // MARK: - Buffer creation

    /// macOS-style buffer allocation. Managed storage is converted to shared with the
    /// documented coherence note, and the requested length is guarded against the
    /// runtime maxBufferLength so a Mac-tuned allocation fails clearly.
    public func makeBuffer(length: Int, macStorageMode: BridgeStorageMode) throws -> MTLBuffer {
        try limits.validateBufferLength(length)
        return try storage.makeBuffer(device: device, length: length, mode: macStorageMode)
    }

    // MARK: - Texture creation

    /// The result of a texture allocation: the texture plus a plain-language note of
    /// what the bridge did with the macOS request.
    public struct TextureResult {
        public let texture: MTLTexture
        /// Why the texture is what it is (native, decoded, or blitted).
        public let note: String
        /// True when the payload went through the BC decode path.
        public let isDecoded: Bool
    }

    /// Creates a texture from compressed macOS-style data.
    ///
    /// BC formats (MTLPixelFormat 130-143) cannot be sampled on Apple GPUs below
    /// Apple7, so the raw BC payload is decoded into an RGBA texture the A9 can
    /// sample. The kernels are bit-exact against bcdec (validated by the
    /// differential harness); sRGB payloads decode into an sRGB output format so
    /// linearization stays in the sampler.
    ///
    /// Non-BC formats take the normal native path (managed storage is converted,
    /// see `StorageModeAdapter`). Requesting private storage with a BC payload
    /// decodes to shared memory first and then blits into a private texture.
    public func makeTexture(rawData: Data,
                            pixelFormat: MTLPixelFormat,
                            width: Int,
                            height: Int,
                            usage: MTLTextureUsage = [.shaderRead],
                            macStorageMode: BridgeStorageMode = .shared) throws -> TextureResult {
        guard let bcFormat = BCDecoder.Format(rawValue: Int(pixelFormat.rawValue)) else {
            let texture = try storage.makeTexture(device: device,
                                                  width: width,
                                                  height: height,
                                                  pixelFormat: pixelFormat,
                                                  usage: usage,
                                                  mode: macStorageMode)
            return TextureResult(texture: texture,
                                 note: "Native \(pixelFormat) texture; storage mode resolved through the bridge.",
                                 isDecoded: false)
        }

        guard macStorageMode != .memoryless else {
            throw BridgeError.unsupported("Memoryless storage cannot hold a BC payload or its decode target.")
        }

        let decoded = try bcDecode.decodeTexture(rawData: rawData,
                                                 format: bcFormat,
                                                 width: width,
                                                 height: height,
                                                 usage: usage)

        if macStorageMode == .privateMode {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: bcFormat.outputPixelFormat,
                                                                      width: width,
                                                                      height: height,
                                                                      mipmapped: decoded.mipmapLevelCount > 1)
            descriptor.usage = usage
            descriptor.storageMode = MTLStorageMode.private
            guard let privateTexture = device.makeTexture(descriptor: descriptor) else {
                throw BridgeError.allocationFailed("Failed to allocate the private decode target for \(width)x\(height).")
            }
            guard let queue = device.makeCommandQueue(),
                  let commandBuffer = queue.makeCommandBuffer(),
                  let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw BridgeError.operationFailed("Failed to blit the BC decode result into private storage.")
            }
            for level in 0..<decoded.mipmapLevelCount {
                blit.copy(from: decoded,
                          sourceSlice: 0,
                          sourceLevel: level,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: max(1, width >> level), height: max(1, height >> level), depth: 1),
                          to: privateTexture,
                          destinationSlice: 0,
                          destinationLevel: level,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                throw BridgeError.operationFailed("BC decode private-storage blit failed: \(error)")
            }
            return TextureResult(texture: privateTexture,
                                 note: "\(bcFormat) decoded to \(bcFormat.outputPixelFormat) in shared memory, blitted into private storage.",
                                 isDecoded: true)
        }

        let note = macStorageMode == .managed
            ? "\(bcFormat) decoded to \(bcFormat.outputPixelFormat); managed storage mapped to shared."
            : "\(bcFormat) decoded to \(bcFormat.outputPixelFormat) — hardware BC sampling needs Apple7."
        return TextureResult(texture: decoded, note: note, isDecoded: true)
    }


    // MARK: - Command queues

    public func makeCommandQueue() throws -> MTLCommandQueue {
        guard let queue = device.makeCommandQueue() else {
            throw BridgeError.operationFailed("MTLDevice.makeCommandQueue returned nil.")
        }
        return queue
    }

    // MARK: - Pipelines

    /// Wraps a render pipeline descriptor with the bridge's MSAA policy before
    /// compilation. The MSAA service downlevels sample counts above the Apple GPU
    /// maximum (4x) to 4x and reports the decision.
    public func makeRenderPipelineState(_ descriptor: MTLRenderPipelineDescriptor) throws -> (MTLRenderPipelineState, BridgeOperationResult) {
        var report: BridgeOperationResult = .performed("Pipeline compiled natively.")
        let requested = descriptor.sampleCount
        if requested > 1 {
            let clamped = MSAAService.resolve(sampleCount: requested, supported: limits.supportedSampleCounts)
            if clamped.count != requested {
                descriptor.sampleCount = clamped.count
                report = .partial(clamped.note)
            }
        }
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        return (state, report)
    }

    // MARK: - Diagnostics

    public var deviceSummary: [(String, String)] {
        var rows: [(String, String)] = [
            ("Device", capabilities.deviceName),
            ("OS", capabilities.operatingSystem),
            ("GPU families", capabilities.gpuFamilies.joined(separator: ", ")),
            ("Metal 3", capabilities.supportsMetal3 ? "Yes" : "No"),
            ("Metal 4", capabilities.supportsMetal4 ? "Yes" : "No")
        ]
        rows += limits.summary
        return rows
    }
}
