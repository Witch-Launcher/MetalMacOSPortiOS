import XCTest
import Metal
@testable import MetalBridgeKit

final class TessellationEmulatorTests: XCTestCase {
    private var device: MTLDevice!
    private var facade: MacMetalDevice!
    private var emulator: TessellationEmulator!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        self.device = device
        self.facade = try MacMetalDevice(device: device)
        self.emulator = facade.tessellation
    }

    private func halfBits(_ value: Float) -> UInt16 {
        Float16(value).bitPattern
    }

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for (index, key) in ["x", "y", "z"].enumerated() {
            XCTAssertLessThan(abs(a[index] - b[index]), accuracy, "\(message) component \(key)", file: file, line: line)
        }
    }

    func testQuadPatchProducesUniformGrid() throws {
        let function = try emulator.makeDemoDomainFunction(patchType: .quad)
        let controlPoints: [Float] = [0, 0, 0,  1, 0, 0,  0, 1, 0,  1, 1, 0]
        let factors: [UInt16] = [halfBits(2), halfBits(2), halfBits(2), halfBits(2), halfBits(2), halfBits(2)]

        let controlBuffer = device.makeBuffer(bytes: controlPoints, length: controlPoints.count * 4, options: .storageModeShared)!
        let factorBuffer = device.makeBuffer(bytes: factors, length: factors.count * 2, options: .storageModeShared)!

        let queue = try facade.makeCommandQueue()
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw XCTSkip("Command buffer unavailable.")
        }
        let request = TessellationEmulator.DrawRequest(
            patchType: .quad, partitionMode: .integer, winding: .clockwise,
            patchCount: 1, controlPointStride: 48, vertexStride: 16,
            controlPointBuffer: controlBuffer, factorBuffer: factorBuffer)
        let draw = try emulator.tessellate(request, domainFunction: function, into: commandBuffer)
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(draw.vertexCount, 9)      // (2+1)^2 grid
        XCTAssertEqual(draw.indexCount, 24)      // 4 cells, 2 triangles each
        XCTAssertEqual(draw.approximations.count, 0)

        let vertices = draw.vertexBuffer.contents().bindMemory(to: Float.self, capacity: 36)
        // Corner samples must hit the control points exactly.
        let positions: [SIMD3<Float>] = (0..<9).map { SIMD3<Float>(vertices[$0 * 4], vertices[$0 * 4 + 1], vertices[$0 * 4 + 2]) }
        XCTAssertEqual(positions[0].x, 0, accuracy: 0.0001)   // (u=0, v=0)
        assertClose(positions[2], SIMD3<Float>(1, 0, 0), accuracy: 0.0001, "u=1, v=0")   // (u=1, v=0)
        assertClose(positions[6], SIMD3<Float>(0, 1, 0), accuracy: 0.0001, "u=0, v=1")   // (u=0, v=1)
        assertClose(positions[8], SIMD3<Float>(1, 1, 0), accuracy: 0.0001, "u=1, v=1")   // (u=1, v=1)
        assertClose(positions[4], SIMD3<Float>(0.5, 0.5, 0), accuracy: 0.0001, "center") // center
    }

    func testTrianglePatchProducesBarycentricLattice() throws {
        let function = try emulator.makeDemoDomainFunction(patchType: .triangle)
        let controlPoints: [Float] = [0, 0, 0,  1, 0, 0,  0, 1, 0]
        let factors: [UInt16] = [halfBits(2), halfBits(2), halfBits(2), halfBits(2)]

        let controlBuffer = device.makeBuffer(bytes: controlPoints, length: controlPoints.count * 4, options: .storageModeShared)!
        let factorBuffer = device.makeBuffer(bytes: factors, length: factors.count * 2, options: .storageModeShared)!

        let queue = try facade.makeCommandQueue()
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw XCTSkip("Command buffer unavailable.")
        }
        let request = TessellationEmulator.DrawRequest(
            patchType: .triangle, partitionMode: .integer, winding: .clockwise,
            patchCount: 1, controlPointStride: 36, vertexStride: 16,
            controlPointBuffer: controlBuffer, factorBuffer: factorBuffer)
        let draw = try emulator.tessellate(request, domainFunction: function, into: commandBuffer)
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(draw.vertexCount, 6)      // (2+1)(2+2)/2 lattice points
        XCTAssertEqual(draw.indexCount, 12)      // 2^2 = 4 triangles
        let vertices = draw.vertexBuffer.contents().bindMemory(to: Float.self, capacity: 24)
        let positions: [SIMD3<Float>] = (0..<6).map { SIMD3<Float>(vertices[$0 * 4], vertices[$0 * 4 + 1], vertices[$0 * 4 + 2]) }
        let maxIndex = positions.map { max($0.x, $0.y) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxIndex, 1.0 + 0.0001)
        // All samples lie on the z=0 plane spanned by the control points.
        for position in positions {
            XCTAssertEqual(position.z, 0, accuracy: 0.0001)
        }
    }

    func testFractionalPartitionClampsToInteger() throws {
        let function = try emulator.makeDemoDomainFunction(patchType: .quad)
        let controlPoints = [Float](repeating: 0, count: 12)
        let factors: [UInt16] = [halfBits(2.5), halfBits(2.5), halfBits(2.5), halfBits(2.5), halfBits(2.5), halfBits(2.5)]
        let controlBuffer = device.makeBuffer(bytes: controlPoints, length: controlPoints.count * 4, options: .storageModeShared)!
        let factorBuffer = device.makeBuffer(bytes: factors, length: factors.count * 2, options: .storageModeShared)!
        let queue = try facade.makeCommandQueue()
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw XCTSkip("Command buffer unavailable.")
        }
        let request = TessellationEmulator.DrawRequest(
            patchType: .quad, partitionMode: .fractionalOdd, winding: .clockwise,
            patchCount: 1, controlPointStride: 48, vertexStride: 16,
            controlPointBuffer: controlBuffer, factorBuffer: factorBuffer)
        let draw = try emulator.tessellate(request, domainFunction: function, into: commandBuffer)
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(draw.vertexCount, 16) // integer 3 -> 4x4 grid
        XCTAssertTrue(draw.approximations.contains { $0.contains("fractionalOdd") })
    }

    func testTopologyCacheReusesIndexBuffer() throws {
        let function = try emulator.makeDemoDomainFunction(patchType: .triangle)
        let controlPoints = [Float](repeating: 0, count: 9)
        let factors: [UInt16] = [halfBits(3), halfBits(3), halfBits(3), halfBits(3)]
        let controlBuffer = device.makeBuffer(bytes: controlPoints, length: controlPoints.count * 4, options: .storageModeShared)!
        let factorBuffer = device.makeBuffer(bytes: factors, length: factors.count * 2, options: .storageModeShared)!
        let queue = try facade.makeCommandQueue()
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw XCTSkip("Command buffer unavailable.")
        }
        let request = TessellationEmulator.DrawRequest(
            patchType: .triangle, partitionMode: .integer, winding: .counterClockwise,
            patchCount: 1, controlPointStride: 36, vertexStride: 16,
            controlPointBuffer: controlBuffer, factorBuffer: factorBuffer)
        let first = try emulator.tessellate(request, domainFunction: function, into: commandBuffer)
        let second = try emulator.tessellate(request, domainFunction: function, into: commandBuffer)
        XCTAssertTrue(first.indexBuffer === second.indexBuffer)
    }

    func testOversizedRequestFailsClearly() throws {
        let function = try emulator.makeDemoDomainFunction(patchType: .quad)
        let controlPoints = [Float](repeating: 0, count: 12)
        let factors: [UInt16] = [halfBits(16), halfBits(16), halfBits(16), halfBits(16), halfBits(16), halfBits(16)]
        let controlBuffer = device.makeBuffer(bytes: controlPoints, length: controlPoints.count * 4, options: .storageModeShared)!
        let factorBuffer = device.makeBuffer(bytes: factors, length: factors.count * 2, options: .storageModeShared)!
        let queue = try facade.makeCommandQueue()
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw XCTSkip("Command buffer unavailable.")
        }
        // maxBufferLength + 1 worth of vertices through a huge patch count.
        let vertexStride = 16
        let patches = (device.maxBufferLength / vertexStride) + 1
        let request = TessellationEmulator.DrawRequest(
            patchType: .quad, partitionMode: .integer, winding: .clockwise,
            patchCount: patches, controlPointStride: 48, vertexStride: vertexStride,
            controlPointBuffer: controlBuffer, factorBuffer: factorBuffer)
        XCTAssertThrowsError(try emulator.tessellate(request, domainFunction: function, into: commandBuffer)) { error in
            guard case let BridgeError.allocationFailed(message) = error else {
                return XCTFail("Expected an allocationFailed error, got \(error).")
            }
            XCTAssertTrue(message.contains("maxBufferLength"), message)
        }
    }
}
