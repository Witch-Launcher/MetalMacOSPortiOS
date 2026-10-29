import XCTest
import Metal
@testable import MetalBridgeKit

final class MetalSmokeTests: XCTestCase {
    func testManagedBufferBecomesSharedAndNeedsNoModifyRange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        let bridge = try MetalBridge(device: device)
        let buffer = try bridge.makeBuffer(length: 64, mode: .managed)
        XCTAssertEqual(buffer.storageMode, .shared)

        let result = try bridge.synchronization.didModifyRange(buffer, range: 0..<64)
        guard case .noActionRequired = result else {
            return XCTFail("Expected no action for a shared buffer.")
        }
    }

    func testPrivateBufferRejectsCPUUpdate() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        let bridge = try MetalBridge(device: device)
        let buffer = try bridge.makeBuffer(length: 64, mode: .privateMode)
        XCTAssertEqual(buffer.storageMode, .private)
        XCTAssertThrowsError(try bridge.synchronization.didModifyRange(buffer, range: 0..<64))
    }

    func testManagedTextureBecomesShared() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        let bridge = try MetalBridge(device: device)
        let texture = try bridge.makeTexture(width: 8,
                                             height: 8,
                                             pixelFormat: .bgra8Unorm,
                                             usage: [.shaderRead, .renderTarget],
                                             mode: .managed)
        XCTAssertEqual(texture.storageMode, .shared)
    }

    func testMemorylessBufferIsRejected() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        let bridge = try MetalBridge(device: device)
        XCTAssertThrowsError(try bridge.makeBuffer(length: 64, mode: .memoryless))
    }

    func testRemoteStorageIsExplicitlyUnsupported() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        let bridge = try MetalBridge(device: device)
        let buffer = try bridge.makeBuffer(length: 64, mode: .shared)
        XCTAssertThrowsError(try bridge.remoteResources.remoteStorageBuffer(for: buffer))
        XCTAssertThrowsError(try bridge.remoteResources.newRemoteBufferView(for: buffer, device: device))
    }

    func testDeviceLocationIsConverted() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        let bridge = try MetalBridge(device: device)
        let location = bridge.deviceAdapter.location
        guard case let .converted(value, note) = location else {
            return XCTFail("Expected a converted device location.")
        }
        XCTAssertEqual(value, .builtIn)
        XCTAssertFalse(note.isEmpty)
        XCTAssertEqual(bridge.deviceAdapter.peerCount.value, 1)
    }
}
