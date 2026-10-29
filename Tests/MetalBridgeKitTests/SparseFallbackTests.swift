import XCTest
import Metal
@testable import MetalBridgeKit

final class SparseFallbackTests: XCTestCase {
    private var device: MTLDevice!
    private var facade: MacMetalDevice!
    private var sparse: SparseFallback!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        self.device = device
        self.facade = try MacMetalDevice(device: device)
        self.sparse = facade.sparse!
    }

    func testPageGridMathStaysWithinPageSize() throws {
        let texture = try sparse.makeTexture(pixelFormat: .rgba8Unorm, width: 256, height: 128)
        // 4 bytes per texel -> tileSide = sqrt(16384/4) = 64 texels.
        XCTAssertEqual(texture.tileSide, 64)
        XCTAssertEqual(texture.pagesWide(mipLevel: 0), 4)
        XCTAssertEqual(texture.pagesHigh(mipLevel: 0), 2)
        XCTAssertLessThanOrEqual(texture.pageSizeBytes, SparseFallback.pageSize)

        // Mips shrink the page grid but never below one page.
        XCTAssertEqual(texture.pagesWide(mipLevel: 1), 2)
        XCTAssertEqual(texture.pagesHigh(mipLevel: 1), 1)
    }

    func testUnmappedPagesReadZerosAndDeallocateZeroes() throws {
        let texture = try sparse.makeTexture(pixelFormat: .rgba8Unorm, width: 64, height: 64)
        XCTAssertEqual(texture.pagesWide(mipLevel: 0), 1)
        XCTAssertEqual(texture.pagesHigh(mipLevel: 0), 1)
        // Nothing allocated yet: reads are zeros.
        var bytes = [UInt8](repeating: 0xEE, count: 64 * 64 * 4)
        try texture.texture.getBytes(&bytes, bytesPerRow: 64 * 4, bytesPerImage: 0,
                                 from: MTLRegionMake3D(0, 0, 0, 64, 64, 1), mipmapLevel: 0, slice: 0)
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 }, "fresh sparse fallback must read as zeros")

        // Write a pattern, then deallocate and confirm the zeroing.
        try texture.allocate([SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0)])
        XCTAssertTrue(texture.isPageAllocated(SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0)))
        var pattern = [UInt8](repeating: 0xAB, count: 64 * 64 * 4)
        try texture.texture.replace(region: MTLRegionMake2D(0, 0, 64, 64),
                                mipmapLevel: 0,
                                withBytes: &pattern,
                                bytesPerRow: 64 * 4)
        try texture.deallocate([SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0)])
        XCTAssertFalse(texture.isPageAllocated(SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0)))
        var after = [UInt8](repeating: 0xEE, count: 64 * 64 * 4)
        try texture.texture.getBytes(&after, bytesPerRow: 64 * 4, bytesPerImage: 0,
                                 from: MTLRegionMake3D(0, 0, 0, 64, 64, 1), mipmapLevel: 0, slice: 0)
        XCTAssertTrue(after.allSatisfy { $0 == 0 }, "deallocated pages must read as zeros")
    }

    func testMappingChangedEventAdvancesPerPass() throws {
        let texture = try sparse.makeTexture(pixelFormat: .rgba8Unorm, width: 128, height: 128)
        let event = texture.mappingChangedEvent
        let start = event.signaledValue
        try texture.allocate([SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0),
                          SparseTexture.Page(mipLevel: 0, pageX: 1, pageY: 0)])
        XCTAssertEqual(event.signaledValue, start + 1)
        try texture.deallocate([SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0)])
        XCTAssertEqual(event.signaledValue, start + 2)
        try texture.updateMappings([(SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0), true),
                                (SparseTexture.Page(mipLevel: 0, pageX: 1, pageY: 0), false)])
        XCTAssertEqual(event.signaledValue, start + 3)
        XCTAssertTrue(texture.isPageAllocated(SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0)))
        XCTAssertFalse(texture.isPageAllocated(SparseTexture.Page(mipLevel: 0, pageX: 1, pageY: 0)))
    }

    func testInvalidPagesAndSlicesThrow() throws {
        let texture = try sparse.makeTexture(pixelFormat: .rgba8Unorm, width: 64, height: 64)
        XCTAssertThrowsError(try texture.allocate([SparseTexture.Page(mipLevel: 0, pageX: 5, pageY: 0)]))
        XCTAssertThrowsError(try texture.allocate([SparseTexture.Page(mipLevel: 4, pageX: 0, pageY: 0)]))
        XCTAssertThrowsError(try texture.allocate([SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0)], slice: 3))
    }
}
