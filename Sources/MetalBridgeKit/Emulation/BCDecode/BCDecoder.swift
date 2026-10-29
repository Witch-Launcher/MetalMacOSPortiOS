import Foundation
import Metal

/// Decodes macOS BC-compressed textures into samplable RGBA textures on Apple GPUs
/// without hardware BC support (BC sampling requires Apple7; A9 tops out at Apple3).
///
/// The kernels in Shaders/BCDecode.metal are a bit-exact port of bcdec v0.985
/// (MIT OR Unlicense, vendored at third_party/bcdec/bcdec.h). Differential tests
/// in the test target run bcdec on the CPU and compare texel-by-texel against the
/// GPU result, so "compatible with macOS decoders" is a tested property, not a claim.
public final class BCDecoder {
    /// The BC formats macOS content can carry, keyed by their MTLPixelFormat values
    /// (130-143). Metal exposes these raw values on iOS even where sampling is
    /// unavailable, so the bridge keys on the format value it receives.
    public enum Format: Int, CaseIterable {
        case bc1rgba = 130
        case bc1rgbaSRGB = 131
        case bc2rgba = 132
        case bc2rgbaSRGB = 133
        case bc3rgba = 134
        case bc3rgbaSRGB = 135
        case bc4rUnorm = 136
        case bc4rSnorm = 137
        case bc5rgUnorm = 138
        case bc5rgSnorm = 139
        case bc6hrgbFloat = 140
        case bc6hrgbuFloat = 141
        case bc7rgbaUnorm = 142
        case bc7rgbaUnormSRGB = 143

        public var kernelName: String {
            switch self {
            case .bc1rgba, .bc1rgbaSRGB: return "mb_bc1_decode"
            case .bc2rgba, .bc2rgbaSRGB: return "mb_bc2_decode"
            case .bc3rgba, .bc3rgbaSRGB: return "mb_bc3_decode"
            case .bc4rUnorm, .bc4rSnorm: return "mb_bc4_decode"
            case .bc5rgUnorm, .bc5rgSnorm: return "mb_bc5_decode"
            case .bc6hrgbFloat, .bc6hrgbuFloat: return "mb_bc6h_decode"
            case .bc7rgbaUnorm, .bc7rgbaUnormSRGB: return "mb_bc7_decode"
            }
        }

        public var isSigned: Bool {
            switch self {
            case .bc4rSnorm, .bc5rgSnorm, .bc6hrgbFloat: return true
            default: return false
            }
        }

        public var isSRGB: Bool {
            switch self {
            case .bc1rgbaSRGB, .bc2rgbaSRGB, .bc3rgbaSRGB, .bc7rgbaUnormSRGB: return true
            default: return false
            }
        }

        /// The decoded texture format. BC4 keeps R in all channels so scalar reads
        /// keep working; BC5 zeroes B and A. BC6H decodes to 16-bit float.
        public var outputPixelFormat: MTLPixelFormat {
            switch self {
            case .bc6hrgbFloat, .bc6hrgbuFloat: return .rgba16Float
            case .bc4rSnorm, .bc5rgSnorm: return .rgba8Snorm
            default: return isSRGB ? .rgba8Unorm_srgb : .rgba8Unorm
            }
        }

        public var blockSize: Int {
            switch self {
            case .bc1rgba, .bc1rgbaSRGB, .bc4rUnorm, .bc4rSnorm: return 8
            default: return 16
            }
        }

        /// Bytes per pixel after decode, for allocation math.
        public var decodedBytesPerPixel: Int {
            self == .bc6hrgbFloat || self == .bc6hrgbuFloat ? 8 : 4
        }
    }

    public struct DecodeError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public let device: MTLDevice
    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private var library: MTLLibrary?

    public init(device: MTLDevice) {
        self.device = device
    }

    /// Decodes a full mip chain. The input layout matches Metal's native BC texture
    /// memory: for each mip, ((width+3)/4) x ((height+3)/4) blocks of `blockSize`
    /// bytes, row-major, starting at the largest mip. The returned texture is
    /// mipmapped and in shared storage (replaceRegion is a CPU copy on this path;
    /// an app can blit it into private storage itself if it wants).
    public func decodeTexture(rawData: Data,
                              format: Format,
                              width: Int,
                              height: Int,
                              usage: MTLTextureUsage = [.shaderRead]) throws -> MTLTexture {
        try validateDimensions(width: width, height: height)
        let mipCount = Self.mipCount(width: width, height: height)
        let expected = Self.compressedSize(format: format, width: width, height: height)
        guard rawData.count >= expected else {
            throw DecodeError(message: """
            BC payload too small for \(width)x\(height) \(format): need \(expected) bytes, got \(rawData.count).
            """)
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.pixelFormat = format.outputPixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.mipmapLevelCount = mipCount
        descriptor.usage = usage
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw DecodeError(message: "Failed to allocate \(width)x\(height) decode target.")
        }

        var offset = 0
        for mip in 0..<mipCount {
            let mipWidth = max(1, width >> mip)
            let mipHeight = max(1, height >> mip)
            let blocksWide = (mipWidth + 3) / 4
            let blocksHigh = (mipHeight + 3) / 4
            let mipBytes = blocksWide * blocksHigh * format.blockSize
            let mipData = rawData.subdata(in: offset..<(offset + mipBytes))
            try self.decodeLevel(mipData, format: format, width: mipWidth, height: mipHeight, into: texture, mipLevel: mip)
            offset += mipBytes
        }
        return texture
    }

    /// Decodes one mip level and uploads it into `texture`.
    public func decodeMip(_ mipData: Data,
                          format: Format,
                          width: Int,
                          height: Int,
                          into texture: MTLTexture,
                          mipLevel: Int) throws {
        try validateDimensions(width: width, height: height)
        try decodeLevel(mipData, format: format, width: width, height: height, into: texture, mipLevel: mipLevel)
    }

    /// Decode core without the public dimension guard: mip levels below 4 pixels
    /// are legal (their BC footprint is one block), so the mip-chain walk uses this
    /// directly after validating the base dimensions.
    private func decodeLevel(_ mipData: Data,
                             format: Format,
                             width: Int,
                             height: Int,
                             into texture: MTLTexture,
                             mipLevel: Int) throws {
        let blocksWide = (width + 3) / 4
        let blocksHigh = (height + 3) / 4
        guard mipData.count >= blocksWide * blocksHigh * format.blockSize else {
            throw DecodeError(message: "Mip payload too small: \(width)x\(height) needs \(blocksWide * blocksHigh * format.blockSize) bytes.")
        }

        let queue = try self.queue()
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw DecodeError(message: "Failed to create a command buffer for BC decode.")
        }

        var params = BCParamsLayout()
        params.widthPixels = UInt32(width)
        params.heightPixels = UInt32(height)
        params.flags = format.isSigned ? 1 : 0

        guard let paramsBuffer = device.makeBuffer(bytes: &params, length: MemoryLayout<BCParamsLayout>.size, options: .storageModeShared),
              let blocksBuffer = device.makeBuffer(bytes: [UInt8](mipData), length: mipData.count, options: .storageModeShared) else {
            throw DecodeError(message: "Failed to allocate BC decode staging buffers.")
        }
        let outputBytes = blocksWide * 4 * blocksHigh * 4 * format.decodedBytesPerPixel
        guard let outputBuffer = device.makeBuffer(length: outputBytes, options: .storageModeShared) else {
            throw DecodeError(message: "Failed to allocate the \(outputBytes)-byte decode output.")
        }

        let pipeline = try self.pipelineState(for: format)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw DecodeError(message: "Failed to create a compute encoder for BC decode.")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(blocksBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 2)
        let threads = MTLSize(width: blocksWide, height: blocksHigh, depth: 1)
        let group = MTLSize(width: pipeline.threadExecutionWidth,
                            height: max(1, pipeline.maxTotalThreadsPerThreadgroup / pipeline.threadExecutionWidth),
                            depth: 1)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: group)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw DecodeError(message: "BC decode command buffer failed: \(error)")
        }

        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: mipLevel,
                        withBytes: outputBuffer.contents(),
                        bytesPerRow: blocksWide * 4 * format.decodedBytesPerPixel)
    }

    // MARK: - Layout math (shared with tests)

    public static func mipCount(width: Int, height: Int) -> Int {
        var w = width
        var h = height
        var levels = 1
        while w > 1 || h > 1 {
            w = max(1, w >> 1)
            h = max(1, h >> 1)
            levels += 1
        }
        return levels
    }

    public static func compressedSize(format: Format, width: Int, height: Int) -> Int {
        var total = 0
        var w = width
        var h = height
        while true {
            total += ((w + 3) / 4) * ((h + 3) / 4) * format.blockSize
            if w == 1 && h == 1 { break }
            w = max(1, w >> 1)
            h = max(1, h >> 1)
        }
        return total
    }

    // MARK: - Internals

    private func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width % 4 == 0, height % 4 == 0 else {
            throw DecodeError(message: "BC textures require positive dimensions that are multiples of 4; got \(width)x\(height).")
        }
    }

    private var commandQueue: MTLCommandQueue?
    private func queue() throws -> MTLCommandQueue {
        if let queue = commandQueue { return queue }
        guard let queue = device.makeCommandQueue() else {
            throw DecodeError(message: "Failed to create a command queue for BC decode.")
        }
        commandQueue = queue
        return queue
    }

    private func frameworkLibrary() throws -> MTLLibrary {
        if let library = library { return library }
        let bundle = Bundle(for: BCDecoder.self)
        // The metallib ships with the app in some layouts (the Lab compiles
        // Shaders/ into the app target) and with the framework in others, so
        // try both before giving up.
        let loaded = (try? device.makeDefaultLibrary(bundle: bundle))
            ?? (try? device.makeDefaultLibrary(bundle: Bundle.main))
        guard let loaded = loaded else {
            throw DecodeError(message: "The MetalBridgeKit metallib is unavailable; BC decode kernels are missing.")
        }
        library = loaded
        return loaded
    }

    private func pipelineState(for format: Format) throws -> MTLComputePipelineState {
        if let cached = pipelineCache[format.kernelName] { return cached }
        let loaded = try self.frameworkLibrary()
        guard let function = loaded.makeFunction(name: format.kernelName) else {
            throw DecodeError(message: "Kernel \(format.kernelName) is missing from the framework metallib.")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        pipelineCache[format.kernelName] = pipeline
        return pipeline
    }
}

/// Mirrors struct BCParams in Shaders/BCDecode.metal. Keep in sync.
struct BCParamsLayout {
    var widthPixels: UInt32 = 0
    var heightPixels: UInt32 = 0
    var flags: UInt32 = 0
}
