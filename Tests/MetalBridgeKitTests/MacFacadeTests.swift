import XCTest
import Metal
@testable import MetalBridgeKit

final class MacFacadeTests: XCTestCase {
    private func makeFacade() throws -> MacMetalDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        return try MacMetalDevice(device: device)
    }

    func testFacadeExposesLimitProfile() throws {
        let facade = try makeFacade()
        XCTAssertGreaterThan(facade.limits.maxBufferLength, 0)
        XCTAssertGreaterThan(facade.limits.maxThreadgroupMemoryLength, 0)
        XCTAssertFalse(facade.limits.supportedSampleCounts.isEmpty)
        XCTAssertEqual(facade.limits.maxTessellationFactor, facade.capabilities.familyNumbers.max().map { $0 >= 4 ? 64 : 16 })
    }

    func testBufferLengthGuardRejectsOversizedAllocation() throws {
        let facade = try makeFacade()
        let oversized = Int(facade.limits.maxBufferLength) + 1
        XCTAssertThrowsError(try facade.limits.validateBufferLength(oversized)) { error in
            guard case let BridgeError.allocationFailed(message) = error else {
                return XCTFail("Expected an allocationFailed error.")
            }
            XCTAssertTrue(message.contains("maxBufferLength"), message)
        }
    }

    func testBufferLengthGuardAcceptsRealisticAllocation() throws {
        let facade = try makeFacade()
        XCTAssertNoThrow(try facade.limits.validateBufferLength(1024))
    }

    func testMSAAPolicyDownlevelsEightToLargestSupported() {
        // Apple GPU profile: 1, 2, 4 supported.
        let resolution = MSAAService.resolve(sampleCount: 8, supported: [1, 2, 4])
        XCTAssertEqual(resolution.count, 4)
        XCTAssertTrue(resolution.note.contains("8"))

        // A device that supports 8 keeps it native.
        let native = MSAAService.resolve(sampleCount: 8, supported: [1, 2, 4, 8])
        XCTAssertEqual(native.count, 8)

        // A 1x-only profile downlevels to 1.
        let single = MSAAService.resolve(sampleCount: 4, supported: [1])
        XCTAssertEqual(single.count, 1)
    }

    func testTessellationFactorClampMatchesFamilyLimit() throws {
        let facade = try makeFacade()
        let (value, clamped) = facade.limits.clampTessellationFactor(64)
        let expectedMax = Float(facade.limits.maxTessellationFactor)
        XCTAssertEqual(value, expectedMax)
        XCTAssertEqual(clamped, 64 > Int(expectedMax))
    }

    func testMacFeatureSetEvaluationIsExplicitlyPartial() throws {
        let facade = try makeFacade()
        for featureSet in BridgeMacFeatureSet.allCases {
            let result = facade.featureSets.evaluate(featureSet)
            XCTAssertEqual(result.status, .partial, featureSet.rawValue)
            guard case let .partial(satisfied, note) = result else {
                return XCTFail("Expected a partial evaluation for \(featureSet.rawValue).")
            }
            XCTAssertFalse(note.isEmpty, featureSet.rawValue)
            if case .macOS_GPUFamily2_v1 = featureSet, satisfied {
                XCTFail("mac2 feature sets require tier-2 argument buffers, which no current iOS device reports.")
            }
        }
    }

    func testMacFeatureSetChecklistCoversKnownItems() throws {
        let facade = try makeFacade()
        let identifiers = facade.featureSets.runtimeChecks.map { $0.identifier }
        for expected in ["compute", "memoryless", "indirectDrawArguments", "msaa4", "msaa8",
                         "argumentBuffersTier1", "argumentBuffersTier2", "fences",
                         "tessellationNative", "bcSampling", "sparseTextures", "depth24Stencil8"] {
            XCTAssertTrue(identifiers.contains(expected), "Missing capability check: \(expected)")
        }
        for check in facade.featureSets.runtimeChecks {
            XCTAssertFalse(check.basis.isEmpty, check.identifier)
        }
    }

    func testFacadeBufferCreationUsesLimitGuardAndStorageConversion() throws {
        let facade = try makeFacade()
        let buffer = try facade.makeBuffer(length: 128, macStorageMode: .managed)
        XCTAssertEqual(buffer.storageMode, .shared)
        XCTAssertEqual(buffer.length, 128)
    }

    func testFacadePipelineDownlevelReportsDecision() throws {
        let facade = try makeFacade()
        guard let library = try? facade.device.makeDefaultLibrary(bundle: Bundle.main) else {
            throw XCTSkip("No default metallib in the host app bundle.")
        }
        guard let vertex = library.makeFunction(name: "probe_vertex"),
              let fragment = library.makeFunction(name: "probe_fragment") else {
            throw XCTSkip("Probe functions are unavailable in this host bundle.")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.sampleCount = 8
        let (state, report) = try facade.makeRenderPipelineState(descriptor)
        XCTAssertEqual(descriptor.sampleCount, 4)
        XCTAssertNotNil(state)
        guard case .partial = report else {
            return XCTFail("Expected a partial report for the 8x to 4x downlevel.")
        }
    }

    // MARK: - BC texture path

    /// BC1 block: c0=0x0000 black, c1=0xFFFF, all indices 0 -> every texel (0,0,0,255).
    private static let bc1BlackBlock: [UInt8] = [0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00]

    func testMakeTextureRoutesBC1ThroughDecoder() throws {
        let facade = try makeFacade()
        // 4x4 carries a 3-level mip chain (4x4, 2x2, 1x1): three blocks of payload.
        var data = Data()
        for _ in 0..<3 { data.append(Self.bc1BlackBlock, count: 8) }
        let result = try facade.makeTexture(rawData: data,
                                            pixelFormat: MTLPixelFormat(rawValue: 130)!,
                                            width: 4,
                                            height: 4,
                                            usage: [.shaderRead, .shaderWrite])
        XCTAssertTrue(result.isDecoded)
        XCTAssertTrue(result.note.contains("decoded"), result.note)
        XCTAssertEqual(result.texture.pixelFormat, MTLPixelFormat.rgba8Unorm)
        XCTAssertEqual(result.texture.storageMode, MTLStorageMode.shared)

        var bytes = [UInt8](repeating: 0xEE, count: 4 * 4 * 4)
        result.texture.getBytes(&bytes,
                                bytesPerRow: 4 * 4,
                                bytesPerImage: 0,
                                from: MTLRegionMake3D(0, 0, 0, 4, 4, 1),
                                mipmapLevel: 0,
                                slice: 0)
        for texel in 0..<16 {
            let at = texel * 4
            XCTAssertEqual(bytes[at], 0, "texel \(texel) R")
            XCTAssertEqual(bytes[at + 1], 0, "texel \(texel) G")
            XCTAssertEqual(bytes[at + 2], 0, "texel \(texel) B")
            XCTAssertEqual(bytes[at + 3], 255, "texel \(texel) A")
        }
    }

    func testMakeTextureDecodesBC7MipChainAndTexel() throws {
        let facade = try makeFacade()
        // Harness block 0: mode 0, endpoints (8,156,255) / (222,123,156), texel 0 is
        // subset 1's fixup with a 2-bit index of 1 -> weight 9 -> (38,151,241,255).
        let block: [UInt8] = [0x01, 0x1A, 0xFA, 0x25, 0xCF, 0x06, 0xFA, 0xD3,
                              0xE8, 0xED, 0xAA, 0xD7, 0x74, 0xFE, 0x6D, 0x8F]
        // 16x16 mip chain has 23 blocks (16, 4, 1, 1, 1).
        var data = Data()
        for _ in 0..<23 { data.append(block, count: 16) }
        let result = try facade.makeTexture(rawData: data,
                                            pixelFormat: MTLPixelFormat(rawValue: 142)!,
                                            width: 16,
                                            height: 16)
        XCTAssertTrue(result.isDecoded)
        XCTAssertEqual(result.texture.pixelFormat, MTLPixelFormat.rgba8Unorm)
        XCTAssertEqual(result.texture.mipmapLevelCount, 5)

        var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
        result.texture.getBytes(&bytes,
                                bytesPerRow: 16 * 4,
                                bytesPerImage: 0,
                                from: MTLRegionMake3D(0, 0, 0, 16, 16, 1),
                                mipmapLevel: 0,
                                slice: 0)
        XCTAssertEqual(bytes[0], 38, "texel 0 R")
        XCTAssertEqual(bytes[1], 151, "texel 0 G")
        XCTAssertEqual(bytes[2], 241, "texel 0 B")
        XCTAssertEqual(bytes[3], 255, "texel 0 A")
    }

    func testMakeTextureNativePathForNonBCFormat() throws {
        let facade = try makeFacade()
        let result = try facade.makeTexture(rawData: Data(),
                                            pixelFormat: .rgba8Unorm,
                                            width: 8,
                                            height: 8,
                                            usage: [.shaderRead],
                                            macStorageMode: .managed)
        XCTAssertFalse(result.isDecoded)
        XCTAssertEqual(result.texture.pixelFormat, MTLPixelFormat.rgba8Unorm)
        XCTAssertEqual(result.texture.storageMode, MTLStorageMode.shared)
    }

    func testMakeTexturePrivateModeBlitsDecodedResult() throws {
        let facade = try makeFacade()
        var data = Data()
        for _ in 0..<3 { data.append(Self.bc1BlackBlock, count: 8) }
        let result = try facade.makeTexture(rawData: data,
                                            pixelFormat: MTLPixelFormat(rawValue: 130)!,
                                            width: 4,
                                            height: 4,
                                            usage: [.shaderRead],
                                            macStorageMode: .privateMode)
        XCTAssertTrue(result.isDecoded)
        XCTAssertEqual(result.texture.storageMode, MTLStorageMode.private)
    }

    func testMakeTextureRejectsMemorylessBCPayload() throws {
        let facade = try makeFacade()
        XCTAssertThrowsError(try facade.makeTexture(rawData: Data(Self.bc1BlackBlock),
                                                    pixelFormat: MTLPixelFormat(rawValue: 130)!,
                                                    width: 4,
                                                    height: 4,
                                                    macStorageMode: .memoryless)) { error in
            guard case BridgeError.unsupported = error else {
                return XCTFail("Expected an unsupported error.")
            }
        }
    }
}
