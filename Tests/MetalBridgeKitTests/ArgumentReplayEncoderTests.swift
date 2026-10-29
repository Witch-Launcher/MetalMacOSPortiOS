import XCTest
import Metal
@testable import MetalBridgeKit

final class ArgumentReplayEncoderTests: XCTestCase {
    private var device: MTLDevice!
    private var facade: MacMetalDevice!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        self.device = device
        self.facade = try MacMetalDevice(device: device)
    }

    /// The recorded binding sequence must reach a real compute encoder in order.
    /// The BC1 decode kernel is the victim: its params buffer is replayed instead
    /// of bound directly, and the pitch change is observable in the output.
    func testReplayBindingsReachComputeEncoder() throws {
        // One opaque BC1 block: c0=black, c1=white, all indices 0.
        let block: [UInt8] = [0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00]
        let blocksBuffer = try XCTUnwrap(device.makeBuffer(bytes: block, length: 8, options: .storageModeShared))

        // Output is 2 blocks wide; the replayed params say the pitch is 8 pixels,
        // so row 0 covers texels 0-7 and texels 8-15 stay untouched (0xEE marker).
        let outputBuffer = try XCTUnwrap(device.makeBuffer(length: 16 * 4 * 2, options: .storageModeShared))
        memset(outputBuffer.contents(), 0xEE, 16 * 4 * 2)

        var params = BCParamsLayout()
        params.widthPixels = 8
        params.heightPixels = 4
        let paramsBuffer = try XCTUnwrap(device.makeBuffer(bytes: &params,
                                                           length: MemoryLayout<BCParamsLayout>.size,
                                                           options: .storageModeShared))

        let replay = ArgumentReplayEncoder()
        XCTAssertEqual(replay.count, 0)
        replay.encodeSetBuffer(blocksBuffer, offset: 0, index: 0)
        replay.encodeSetBuffer(outputBuffer, offset: 0, index: 1)
        replay.encodeSetBuffer(paramsBuffer, offset: 0, index: 2)
        XCTAssertEqual(replay.count, 3)

        let library = try XCTUnwrap(facade.device.makeDefaultLibrary(bundle: Bundle(for: BCDecoder.self)))
        let function = try XCTUnwrap(library.makeFunction(name: "mb_bc1_decode"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(facade.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        replay.replay(into: encoder)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // One block at pitch 8 writes texels {0-3, 8-11, 16-19, 24-27}; every other
        // texel stays at the 0xEE marker.
        let out = outputBuffer.contents().bindMemory(to: UInt8.self, capacity: 128)
        let written = [0, 1, 2, 3, 8, 9, 10, 11, 16, 17, 18, 19, 24, 25, 26, 27]
        for texel in 0..<32 {
            if written.contains(texel) {
                XCTAssertEqual(out[texel * 4 + 3], 255, "texel \(texel) A")
            } else {
                XCTAssertEqual(out[texel * 4], 0xEE, "texel \(texel) untouched")
            }
        }
    }

    func testRecordedOrderOverridesAndClear() {
        let replay = ArgumentReplayEncoder()
        let bufferA = device.makeBuffer(length: 16, options: .storageModeShared)!
        let bufferB = device.makeBuffer(length: 16, options: .storageModeShared)!
        replay.encodeSetBuffer(bufferA, offset: 0, index: 0)
        replay.encodeSetBuffer(bufferB, offset: 8, index: 0)
        replay.encodeSetBytes(Data([1, 2, 3, 4]), index: 1)
        XCTAssertEqual(replay.count, 3)
        replay.clear()
        XCTAssertEqual(replay.count, 0)
    }
}
