import Foundation
import Metal

// Debug dump: one block per format through CPU (bcdec) and GPU (BCDecode.metal).
setvbuf(stdout, nil, _IONBF, 0)
let metallibPath = "/tmp/mb_bc_test/BCDecode.metallib"
guard let device = MTLCreateSystemDefaultDevice(),
      let lib = try? device.makeLibrary(URL: URL(fileURLWithPath: metallibPath)) else { exit(1) }

final class SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x1234567890ABCDEF : seed }
    func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    func byte() -> UInt8 { UInt8(truncatingIfNeeded: next() & 0xFF) }
}

struct BCParams {
    var widthPixels: UInt32 = 0
    var heightPixels: UInt32 = 0
    var flags: UInt32 = 0
}

func gpuDecode(kernel: String, blocks: [UInt8], signed: Bool, width: Int, height: Int, bytesPerPixel: Int) -> [UInt8] {
    guard let pipeline = try? device.makeComputePipelineState(function: lib.makeFunction(name: kernel)!),
          let queue = device.makeCommandQueue(),
          let commandBuffer = queue.makeCommandBuffer() else {
        print("FAIL pipeline \(kernel)"); exit(1)
    }
    var params = BCParams()
    params.widthPixels = UInt32(width); params.heightPixels = UInt32(height); params.flags = signed ? 1 : 0
    let paramsBuffer = device.makeBuffer(bytes: &params, length: MemoryLayout<BCParams>.size, options: .storageModeShared)!
    let blocksBuffer = device.makeBuffer(bytes: blocks, length: blocks.count, options: .storageModeShared)!
    let outputBuffer = device.makeBuffer(length: width * height * bytesPerPixel, options: .storageModeShared)!
    let encoder = commandBuffer.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(blocksBuffer, offset: 0, index: 0)
    encoder.setBuffer(outputBuffer, offset: 0, index: 1)
    encoder.setBuffer(paramsBuffer, offset: 0, index: 2)
    encoder.dispatchThreads(MTLSize(width: (width + 3) / 4, height: (height + 3) / 4, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    let contents = outputBuffer.contents().assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: contents, count: width * height * bytesPerPixel))
}

func dumpBC2() {
    let kernel = "mb_bc2_decode"
    guard let function = lib.makeFunction(name: kernel) else { exit(1) }
    var block = [UInt8](repeating: 0, count: 16)
    var rng = SeededRandom(seed: 0xABCD1234)
    for i in 0..<16 { block[i] = rng.byte() }
    print("BC2 block:", block.map { String(format: "%02x", $0) }.joined(separator: " "))

    var texels = [UInt8](repeating: 0xAB, count: 16 * 4)
    bcdec_bc2(block, &texels, 16)
    print("CPU:")
    for i in 0..<16 { print("  \(i): \(texels[i*4]) \(texels[i*4+1]) \(texels[i*4+2]) \(texels[i*4+3])") }

    let gpu = gpuDecode(kernel: kernel, blocks: block, signed: false, width: 4, height: 4, bytesPerPixel: 4)
    print("GPU:")
    for i in 0..<16 { print("  \(i): \(gpu[i*4]) \(gpu[i*4+1]) \(gpu[i*4+2]) \(gpu[i*4+3])")
    }
}

func dumpBC4(signed: Bool) {
    let kernel = "mb_bc4_decode"
    guard let function = lib.makeFunction(name: kernel) else { exit(1) }
    var block = [UInt8](repeating: 0, count: 8)
    var rng = SeededRandom(seed: 0xABCD1234)
    for i in 0..<8 { block[i] = rng.byte() }
    block[0] = 0xFF; block[1] = 0xFE // force the 6-value palette
    print("BC4 signed=\(signed) block:", block.map { String(format: "%02x", $0) }.joined(separator: " "))

    var texels = [UInt8](repeating: 0xAB, count: 16 * 4)
    bcdec_bc4(block, &texels, 16, signed ? 1 : 0)
    print("CPU:")
    for i in 0..<16 { print("  \(i): \(texels[i*4])") }

    let gpu = gpuDecode(kernel: kernel, blocks: block, signed: signed, width: 4, height: 4, bytesPerPixel: 4)
    print("GPU:")
    for i in 0..<16 { print("  \(i): \(gpu[i*4]) \(gpu[i*4+1]) \(gpu[i*4+2]) \(gpu[i*4+3])")
    }
}

func dumpBC7(firstByte: UInt8) {
    let kernel = "mb_bc7_decode"
    guard let function = lib.makeFunction(name: kernel) else { exit(1) }
    var block = [UInt8](repeating: 0, count: 16)
    var rng = SeededRandom(seed: 0xABCD1234)
    for i in 0..<16 { block[i] = rng.byte() }
    block[0] = firstByte
    print("BC7 block (first \(String(format: "%02x", firstByte))):", block.map { String(format: "%02x", $0) }.joined(separator: " "))

    var texels = [UInt8](repeating: 0xAB, count: 16 * 4)
    bcdec_bc7(block, &texels, 16)
    print("CPU:")
    for i in 0..<16 { print("  \(i): \(texels[i*4]) \(texels[i*4+1]) \(texels[i*4+2]) \(texels[i*4+3])") }

    let gpu = gpuDecode(kernel: kernel, blocks: block, signed: false, width: 4, height: 4, bytesPerPixel: 4)
    print("GPU:")
    for i in 0..<16 { print("  \(i): \(gpu[i*4]) \(gpu[i*4+1]) \(gpu[i*4+2]) \(gpu[i*4+3])")
    }
}

func dumpBC6H(mode: UInt8, signed: Bool) {
    let kernel = "mb_bc6h_decode"
    guard let function = lib.makeFunction(name: kernel) else { exit(1) }
    var block = [UInt8](repeating: 0, count: 16)
    var rng = SeededRandom(seed: 0xABCD1234)
    for i in 0..<16 { block[i] = rng.byte() }
    block[0] = mode
    print("BC6H mode \(mode) signed=\(signed):", block.map { String(format: "%02x", $0) }.joined(separator: " "))

    var texels = [UInt16](repeating: 0xBEEF, count: 16 * 3)
    bcdec_bc6h_half(block, &texels, 4 * 3, signed ? 1 : 0)
    print("CPU (half bits hex r g b):")
    for i in 0..<16 {
        print("  \(i): \(String(format: "%04x", texels[i*3])) \(String(format: "%04x", texels[i*3+1])) \(String(format: "%04x", texels[i*3+2]))")
    }

    let gpu = gpuDecode(kernel: kernel, blocks: block, signed: signed, width: 4, height: 4, bytesPerPixel: 8)
    print("GPU (half bits hex r g b):")
    for i in 0..<16 {
        let o = i * 8
        print("  \(i): \(String(format: "%04x", UInt16(gpu[o]) | UInt16(gpu[o+1]) << 8)) \(String(format: "%04x", UInt16(gpu[o+2]) | UInt16(gpu[o+3]) << 8)) \(String(format: "%04x", UInt16(gpu[o+4]) | UInt16(gpu[o+5]) << 8))")
    }
}

let which = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
switch which {
case "bc2": dumpBC2()
case "bc4": dumpBC4(signed: false)
case "bc7": dumpBC7(firstByte: 0x01)
case "bc7r": dumpBC7(firstByte: 0x00)
case "bc6h0": dumpBC6H(mode: 0, signed: false)
case "bc6h9": dumpBC6H(mode: 9, signed: false)
case "bc6h10": dumpBC6H(mode: 10, signed: false)
default:
    dumpBC2(); dumpBC4(signed: false); dumpBC7(firstByte: 0x01); dumpBC7(firstByte: 0x00); dumpBC6H(mode: 0, signed: false); dumpBC6H(mode: 9, signed: false); dumpBC6H(mode: 10, signed: false)
}
print("DONE", which)
