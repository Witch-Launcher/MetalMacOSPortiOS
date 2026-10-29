import XCTest
import Metal
@testable import MetalBridgeKit

final class BridgeLogicTests: XCTestCase {
    func testManifestCounts() {
        XCTAssertEqual(CompatibilityManifest.records.count, 42)
        XCTAssertEqual(CompatibilityManifest.count(for: .native), 8)
        XCTAssertEqual(CompatibilityManifest.count(for: .converted), 15)
        XCTAssertEqual(CompatibilityManifest.count(for: .partial), 8)
        XCTAssertEqual(CompatibilityManifest.count(for: .unsupported), 11)
    }

    func testManifestEmulationServiceRecords() {
        let group = CompatibilityManifest.records(in: .emulationServices)
        XCTAssertEqual(group.count, 5)
        XCTAssertEqual(Set(group.map { $0.id }),
                       ["mtl-emulation-bc-decode", "mtl-emulation-tessellation",
                        "mtl-emulation-fences", "mtl-emulation-sparse",
                        "mtl-emulation-argument-replay"])
        XCTAssertEqual(group.filter { $0.status == .converted }.count, 3)
        XCTAssertEqual(group.filter { $0.status == .partial }.count, 2)
    }

    func testManifestIdentifiersAreUnique() {
        let identifiers = CompatibilityManifest.records.map { $0.id }
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
    }

    func testManifestCoversEveryGroup() {
        let groups = Set(CompatibilityManifest.records.map { $0.group })
        XCTAssertEqual(groups, Set(CompatibilityGroup.allCases))
        XCTAssertEqual(CompatibilityManifest.groupedRecords.count, CompatibilityGroup.allCases.count)
    }

    func testManifestRecordsHaveExplanations() {
        for record in CompatibilityManifest.records {
            XCTAssertFalse(record.name.isEmpty, record.id)
            XCTAssertFalse(record.implementation.isEmpty, record.id)
            XCTAssertFalse(record.limitation.isEmpty, record.id)
            XCTAssertNotNil(record.documentationURL, record.id)
        }
    }

    func testManagedStorageIsConvertedToShared() {
        let result = StorageModeAdapter().resolve(.managed)
        guard case let .converted(value, note) = result else {
            return XCTFail("Expected managed storage to be converted.")
        }
        XCTAssertEqual(value, .shared)
        XCTAssertFalse(note.isEmpty)
        XCTAssertEqual(result.status, .converted)
    }

    func testNativeStorageModesRemainNative() {
        let adapter = StorageModeAdapter()
        XCTAssertEqual(adapter.resolve(.shared).status, .native)
        XCTAssertEqual(adapter.resolve(.privateMode).status, .native)
        XCTAssertEqual(adapter.resolve(.memoryless).status, .native)
    }

    func testDepth24StencilFormatIsConverted() {
        let result = PixelFormatAdapter().resolve(.depth24UnormStencil8)
        guard case let .converted(value, note) = result else {
            return XCTFail("Expected depth24 stencil8 to be converted.")
        }
        XCTAssertEqual(value, .depth32Float_stencil8)
        XCTAssertFalse(note.isEmpty)
    }

    func testBridgeErrorExposesLocalizedDescription() {
        let error = BridgeError.unsupported("example")
        XCTAssertEqual(error.localizedDescription, "Unsupported on iOS: example")
    }

    func testPlatformLimitationsAreExplicitlyUnsupported() {
        let adapter = PlatformLimitationAdapter()
        for capability in BridgeUnsupportedCapability.allCases {
            let result = adapter.isSupported(capability)
            XCTAssertEqual(result.status, .unsupported, capability.rawValue)
            XCTAssertNil(result.value, capability.rawValue)
            XCTAssertFalse(capability.reason.isEmpty, capability.rawValue)
        }
    }

    func testX24StencilFormatIsUnsupported() {
        let result = PixelFormatAdapter().resolve(.x24Stencil8)
        guard case let .unsupported(reason) = result else {
            return XCTFail("Expected x24 stencil8 to be unsupported.")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(result.value)
    }

    func testRenderTargetBarrierResolvesToSplitRenderPass() {
        let adapter = BarrierAdapter()
        let resolution = adapter.renderTargetBarrierResolution()
        guard case let .splitRenderPass(note) = resolution else {
            return XCTFail("Expected the split-render-pass resolution for render-target barriers.")
        }
        XCTAssertFalse(note.isEmpty)
        // The deprecated macOS textureBarrier must resolve identically.
        XCTAssertEqual(adapter.legacyTextureBarrierResolution(), resolution)
    }

}
