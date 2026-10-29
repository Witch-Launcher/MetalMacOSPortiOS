import Foundation
import Metal

// Debug dump: BC1 block 0 through both decoders, texel by texel.
let metallibPath = "/tmp/mb_bc_test/BCDecode.metallib"
guard let device = MTLCreateSystemDefaultDevice(),
      let lib = try? device.makeLibrary(URL: URL(fileURLWithPath: metallibPath)),
      let function = lib.makeFunction(name: "mb_bc1_decode") else { exit(1) }

var block: [UInt8] = [0xFF, 0xFE, 0x00, 0x10, 0x20, 0x30, 0x40, 0x50]
print("block bytes:", block.map { String(format: "%02x", $0) }.joined(separator: " "))
let c0 = UInt16(block[0]) | UInt16(block[1]) << 8
let c1 = UInt16(block[2]) | UInt16(block[3]) << 8
print("c0=\(String(format: "%04x", c0)) c1=\(String(format: "%04x", c1)) indices=\(String(format: "%016x", UInt64(block[4]) | UInt64(block[5]) << 8 | UInt64(block[6]) << 16 | UInt64(block[7]) << 24))")

var texels = [UInt8](repeating: 0, count: 16 * 4)
bcdec_bc1(block, &texels, 4)
print("CPU texels:")
for i in 0..<16 {
    print("  \(i): \(texels[i*4]) \(texels[i*4+1]) \(texels[i*4+2]) \(texels[i*4+3])")
}

var params = BCParams(); params.widthPixels = 4; params.heightPixels = 4; params.flags = 0
let pipeline = try! device.makeComputePipelineState(function: function)
let queue = device.makeCommandQueue()!
let commandBuffer = queue.makeCommandBuffer()!
let paramsBuffer = device.makeBuffer(bytes: &params, length: MemoryLayout<BCParams>.size, options: .storageModeShared)!
let blocksBuffer = device.makeBuffer(bytes: block, length: 8, options: .storageModeShared)!
let outputBuffer = device.makeBuffer(length: 16 * 4 * 4, options: .storageModeShared)!
let encoder = commandBuffer.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline)
encoder.setBuffer(blocksBuffer, offset: 0, index: 0)
encoder.setBuffer(outputBuffer, offset: 0, index: 1)
encoder.setBuffer(paramsBuffer, offset: 0, index: 2)
encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
encoder.endEncoding()
commandBuffer.commit()
commandBuffer.waitUntilCompleted()
let gpu = Array(UnsafeBufferPointer(start: outputBuffer.contents().assumingMemoryBound(to: UInt8.self), count: 64))
print("GPU texels:")
for i in 0..<16 {
    print("  \(i): \(gpu[i*4]) \(gpu[i*4+1]) \(gpu[i*4+2]) \(gpu[i*4+3])")
}

struct BCParams {
    var widthPixels: UInt32 = 0
    var heightPixels: UInt32 = 0
    var flags: UInt32 = 0
}
