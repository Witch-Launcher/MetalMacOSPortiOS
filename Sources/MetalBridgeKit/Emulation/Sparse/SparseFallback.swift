import Foundation
import Metal

/// Sparse-texture emulation for A9 devices.
///
/// macOS sparse textures are page-resident: the app allocates pages
/// (`allocateSparsePages`), changes mappings (`updateSparseMappings`), and
/// coordinates with fences. iOS exposes none of that machinery. The bridge
/// backs a sparse texture with a dense, zero-initialized texture and tracks
/// page state itself:
///
/// - Unmapped pages read as zeros, because the dense backing texture starts
///   zeroed and deallocated pages are zero-filled again.
/// - Newly allocated pages are undefined on macOS; here they keep the dense
///   texture's content (zeros at creation, or the app's older data if the
///   page was mapped before). That is safer, and documented.
/// - Writes to pages the app later deallocates are zeroed at deallocation
///   time; a later write would still land in the dense texture (macOS drops
///   writes to unmapped pages - documented difference).
/// - Mapping passes complete synchronously, so the emulated path does not
///   need `MTLFence` completion fences. CPU-side coordination goes through
///   `mappingChangedEvent` (see `FenceBridge`), which advances after every
///   mapping pass.
public final class SparseFallback {
    private let device: MTLDevice

    public init(device: MTLDevice) {
        self.device = device
    }

    public func makeTexture(pixelFormat: MTLPixelFormat,
                            width: Int,
                            height: Int,
                            sliceCount: Int = 1,
                            usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) throws -> SparseTexture {
        guard width > 0, height > 0, sliceCount > 0 else {
            throw BridgeError.invalidArgument("Sparse textures need positive dimensions and slice count; got \(width)x\(height), \(sliceCount) slices.")
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = sliceCount > 1 ? .type2DArray : .type2D
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.arrayLength = sliceCount
        descriptor.mipmapLevelCount = 1
        descriptor.usage = usage
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BridgeError.allocationFailed("Failed to allocate the \(width)x\(height) dense sparse fallback.")
        }
        let bytesPerPixel = SparseFallback.bytesPerPixel(of: pixelFormat)
        guard bytesPerPixel > 0 else {
            throw BridgeError.unsupported("Cannot derive bytes per pixel for \(pixelFormat); the format is not supported as a sparse fallback.")
        }
        // Pages are square texel tiles whose footprint stays within the 16 KB
        // Metal sparse page size.
        let side = max(1, Int((Double(SparseFallback.pageSize) / Double(bytesPerPixel)).squareRoot().rounded(.down)))
        return SparseTexture(texture: texture,
                             sliceCount: sliceCount,
                             tileSide: side,
                             bytesPerPixel: bytesPerPixel)
    }

    /// Metal's sparse page size in bytes.
    public static let pageSize = 16384

    /// Bytes per texel for the formats macOS content plausibly marks sparse.
    /// Returns 0 for formats the fallback does not support (block-compressed
    /// formats have block granularity, not texel granularity).
    public static func bytesPerPixel(of format: MTLPixelFormat) -> Int {
        switch format {
        case .r8Unorm, .r8Unorm_srgb, .r8Snorm, .r8Uint, .r8Sint:
            return 1
        case .rg8Unorm, .rg8Unorm_srgb, .rg8Snorm, .rg8Uint, .rg8Sint,
             .r16Unorm, .r16Snorm, .r16Float, .r16Uint, .r16Sint:
            return 2
        case .rgba8Unorm, .rgba8Unorm_srgb, .rgba8Snorm, .rgba8Uint, .rgba8Sint,
             .bgra8Unorm, .bgra8Unorm_srgb, .bgr10_xr,
             .rg16Unorm, .rg16Snorm, .rg16Float, .rg16Uint, .rg16Sint,
             .r32Uint, .r32Sint, .r32Float,
             .rgb10a2Unorm, .rg11b10Float, .rgb9e5Float:
            return 4
        case .rgba16Unorm, .rgba16Snorm, .rgba16Float, .rgba16Uint, .rgba16Sint,
             .rg32Uint, .rg32Sint, .rg32Float:
            return 8
        case .rgba32Uint, .rgba32Sint, .rgba32Float:
            return 16
        default:
            return 0
        }
    }
}

/// A page-tracked, dense-backed sparse texture.
public final class SparseTexture {
    /// The dense texture all pages live in.
    public let texture: MTLTexture
    /// Texels per page side (square pages).
    public let tileSide: Int
    /// Bytes one full page occupies.
    public let pageSizeBytes: Int
    public let sliceCount: Int
    /// Advances after every mapping pass (allocate, deallocate, updateMappings).
    public let mappingChangedEvent: FenceBridge.Event

    private let lock = NSLock()
    private var allocated: Set<Key> = []
    private let bytesPerPixel: Int

    fileprivate struct Key: Hashable {
        let slice: Int
        let mipLevel: Int
        let pageX: Int
        let pageY: Int
    }

    /// One sparse page reference: mip level plus page coordinates.
    public struct Page: Hashable {
        public let mipLevel: Int
        public let pageX: Int
        public let pageY: Int

        public init(mipLevel: Int, pageX: Int, pageY: Int) {
            self.mipLevel = mipLevel
            self.pageX = pageX
            self.pageY = pageY
        }
    }

    fileprivate init(texture: MTLTexture, sliceCount: Int, tileSide: Int, bytesPerPixel: Int) {
        self.texture = texture
        self.sliceCount = sliceCount
        self.tileSide = tileSide
        self.bytesPerPixel = bytesPerPixel
        self.pageSizeBytes = tileSide * tileSide * bytesPerPixel
        self.mappingChangedEvent = FenceBridge(device: texture.device).makeEvent(label: "sparse.mappingChanged")
    }

    /// Pages across the mip's width.
    public func pagesWide(mipLevel: Int) -> Int {
        let width = mipWidth(mipLevel)
        return (width + tileSide - 1) / tileSide
    }

    /// Pages down the mip's height.
    public func pagesHigh(mipLevel: Int) -> Int {
        let height = mipHeight(mipLevel)
        return (height + tileSide - 1) / tileSide
    }

    public func isPageAllocated(_ page: Page, slice: Int = 0) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allocated.contains(Key(slice: slice, mipLevel: page.mipLevel, pageX: page.pageX, pageY: page.pageY))
    }

    /// Marks pages as allocated. Already-allocated pages are left untouched
    /// (idempotent, unlike macOS which raises).
    public func allocate(_ pages: [Page], slice: Int = 0) throws {
        try self.apply(pages.map { ($0, true) }, slice: slice)
    }

    /// Returns pages to the unmapped state: their texels are zero-filled so
    /// subsequent reads return zeros (macOS semantics).
    public func deallocate(_ pages: [Page], slice: Int = 0) throws {
        try self.apply(pages.map { ($0, false) }, slice: slice)
    }

    /// Applies a batch of mapping updates in order: mapped pages become
    /// allocated, unmapped pages are zeroed and freed.
    public func updateMappings(_ updates: [(page: Page, mapped: Bool)], slice: Int = 0) throws {
        try self.apply(updates, slice: slice)
    }

    private func apply(_ updates: [(page: Page, mapped: Bool)], slice: Int) throws {
        guard slice >= 0, slice < sliceCount else {
            throw BridgeError.invalidArgument("Slice \(slice) is outside the \(sliceCount)-slice texture.")
        }
        var pagesToZero: [Page] = []
        lock.lock()
        do {
            for update in updates {
                try self.validate(page: update.page)
                let key = Key(slice: slice, mipLevel: update.page.mipLevel, pageX: update.page.pageX, pageY: update.page.pageY)
                if update.mapped {
                    allocated.insert(key)
                } else {
                    allocated.remove(key)
                    pagesToZero.append(update.page)
                }
            }
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        // Zero the regions of every unmapped page (the dense texture model).
        for page in pagesToZero {
            try self.zeroPage(page)
        }
        mappingChangedEvent.signal()
    }

    private func validate(page: Page) throws {
        guard page.mipLevel >= 0, page.mipLevel < texture.mipmapLevelCount else {
            throw BridgeError.invalidArgument("Mip level \(page.mipLevel) is outside the texture's \(texture.mipmapLevelCount) levels.")
        }
        guard page.pageX >= 0, page.pageX < pagesWide(mipLevel: page.mipLevel),
              page.pageY >= 0, page.pageY < pagesHigh(mipLevel: page.mipLevel) else {
            throw BridgeError.invalidArgument("Page \(page.pageX),\(page.pageY) is outside the \(pagesWide(mipLevel: page.mipLevel))x\(pagesHigh(mipLevel: page.mipLevel)) page grid of mip \(page.mipLevel).")
        }
    }

    private func mipWidth(_ mipLevel: Int) -> Int {
        return max(1, texture.width >> mipLevel)
    }

    private func mipHeight(_ mipLevel: Int) -> Int {
        return max(1, texture.height >> mipLevel)
    }

    /// Zero-fills the texel bytes one page covers. Runs on shared storage so
    /// this is a CPU memset through replaceRegion.
    private func zeroPage(_ page: Page) throws {
        let width = mipWidth(page.mipLevel)
        let height = mipHeight(page.mipLevel)
        let x0 = page.pageX * tileSide
        let y0 = page.pageY * tileSide
        let spanW = min(tileSide, width - x0)
        let spanH = min(tileSide, height - y0)
        guard spanW > 0, spanH > 0 else {
            throw BridgeError.invalidArgument("Page \(page.pageX),\(page.pageY) has no texels at mip \(page.mipLevel).")
        }
        var zeros = [UInt8](repeating: 0, count: spanW * bytesPerPixel)
        for row in 0..<spanH {
            texture.replace(region: MTLRegionMake2D(x0, y0 + row, spanW, 1),
                            mipmapLevel: page.mipLevel,
                            withBytes: zeros,
                            bytesPerRow: spanW * bytesPerPixel)
        }
    }
}
