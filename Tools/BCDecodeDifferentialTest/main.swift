import Foundation
import Metal

// Differential test harness: decodes random BC blocks on the GPU (BCDecode.metal
// kernels) and on the CPU (vendored bcdec) and compares every texel byte.

let metallibPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/mb_bc_test/BCDecode.metallib"

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

enum FormatKind {
    case bc1, bc2, bc3, bc4, bc5, bc6h, bc7
}

let cases: [(name: String, kernel: String, kind: FormatKind, signed: Bool, modeFirstBytes: [UInt8], blockSize: Int)] = [
    ("BC1", "mb_bc1_decode", .bc1, false, [0xFF, 0xFE, 0x00], 8),
    ("BC2", "mb_bc2_decode", .bc2, false, [], 16),
    ("BC3", "mb_bc3_decode", .bc3, false, [0xFF, 0xFE, 0x00], 16),
    ("BC4 unorm", "mb_bc4_decode", .bc4, false, [0xFF, 0xFE, 0x00], 8),
    ("BC4 snorm", "mb_bc4_decode", .bc4, true, [0xFF, 0xFE, 0x00], 8),
    ("BC5 unorm", "mb_bc5_decode", .bc5, false, [0xFF, 0xFE, 0x00], 16),
    ("BC5 snorm", "mb_bc5_decode", .bc5, true, [0xFF, 0xFE, 0x00], 16),
    ("BC7", "mb_bc7_decode", .bc7, false, [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x00], 16),
]

guard let device = MTLCreateSystemDefaultDevice() else {
    print("FAIL: no Metal device"); exit(1)
}
guard let lib = try? device.makeLibrary(URL: URL(fileURLWithPath: metallibPath)) else {
    print("FAIL: cannot load \(metallibPath)"); exit(1)
}

func decodeGPURun(kernel: String, blocks: [UInt8], signed: Bool, width: Int, height: Int, bytesPerPixel: Int) -> [UInt8] {
    let blocksWide = (width + 3) / 4
    let blocksHigh = (height + 3) / 4
    guard let pipeline = try? device.makeComputePipelineState(function: lib.makeFunction(name: kernel)!),
          let queue = device.makeCommandQueue(),
          let commandBuffer = queue.makeCommandBuffer() else {
        print("FAIL: pipeline/queue creation for \(kernel)"); exit(1)
    }
    var params = BCParams()
    params.widthPixels = UInt32(width)
    params.heightPixels = UInt32(height)
    params.flags = signed ? 1 : 0
    let paramsBuffer = device.makeBuffer(bytes: &params, length: MemoryLayout<BCParams>.size, options: .storageModeShared)!
    let blocksBuffer = device.makeBuffer(bytes: blocks, length: blocks.count, options: .storageModeShared)!
    let outputBytes = blocksWide * 16 * blocksHigh * 4 * bytesPerPixel
    let outputBuffer = device.makeBuffer(length: outputBytes, options: .storageModeShared)!
    let encoder = commandBuffer.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(blocksBuffer, offset: 0, index: 0)
    encoder.setBuffer(outputBuffer, offset: 0, index: 1)
    encoder.setBuffer(paramsBuffer, offset: 0, index: 2)
    encoder.dispatchThreads(MTLSize(width: blocksWide, height: blocksHigh, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(pipeline.threadExecutionWidth, blocksWide), height: 1, depth: 1))
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    if let error = commandBuffer.error {
        print("FAIL: command buffer error \(error)"); exit(1)
    }
    let contents = outputBuffer.contents().assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: contents, count: width * height * bytesPerPixel))
}

func decodeCPU(kind: FormatKind, signed: Bool, blocks: [UInt8], width: Int, height: Int, blockSize: Int) -> [UInt8] {
    let blocksWide = (width + 3) / 4
    let blocksHigh = (height + 3) / 4
    let isHalf = kind == .bc6h
    let bytesPerPixel = isHalf ? 8 : 4
    var result = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    var halves = [UInt16](repeating: 0, count: width * height * 4)

    for by in 0..<blocksHigh {
        for bx in 0..<blocksWide {
            let blockIndex = (by * blocksWide + bx) * blockSize
            let block = Array(blocks[blockIndex..<(blockIndex + blockSize)])
            var texelsRGBA = [UInt8](repeating: 0, count: 16 * 4)
            var texelsHalf = [UInt16](repeating: 0, count: 16 * 3)
            // bcdec's destinationPitch is BYTES PER ROW of the destination buffer:
            // 4 texels x 4 bytes = 16 for RGBA8 buffers (BC6H counts pitch in halfs:
            // 4 texels x 3 halfs = 12).
            switch kind {
            case .bc1: bcdec_bc1(block, &texelsRGBA, 16)
            case .bc2: bcdec_bc2(block, &texelsRGBA, 16)
            case .bc3: bcdec_bc3(block, &texelsRGBA, 16)
            case .bc4: bcdec_bc4(block, &texelsRGBA, 16, signed ? 1 : 0)
            case .bc5: bcdec_bc5(block, &texelsRGBA, 16, signed ? 1 : 0)
            case .bc6h: bcdec_bc6h_half(block, &texelsHalf, 4 * 3, signed ? 1 : 0)
            case .bc7: bcdec_bc7(block, &texelsRGBA, 16)
            }
            for row in 0..<4 {
                for col in 0..<4 {
                    let x = bx * 4 + col
                    let y = by * 4 + row
                    guard x < width, y < height else { continue }
                    let dst = (y * width + x)
                    if isHalf {
                        let src = row * 12 + col * 3
                        halves[dst * 4 + 0] = texelsHalf[src + 0]
                        halves[dst * 4 + 1] = texelsHalf[src + 1]
                        halves[dst * 4 + 2] = texelsHalf[src + 2]
                        halves[dst * 4 + 3] = 0x3C00
                    } else if kind == .bc4 {
                        // bcdec's precise BC4 writes one R byte per texel (pitch 16:
                        // texel (row, col) lives at row*16 + col).
                        rgba[dst * 4 + 0] = texelsRGBA[row * 16 + col]
                    } else if kind == .bc5 {
                        // BC5 packs R,G as 2-byte texels.
                        rgba[dst * 4 + 0] = texelsRGBA[row * 16 + col * 2]
                        rgba[dst * 4 + 1] = texelsRGBA[row * 16 + col * 2 + 1]
                    } else {
                        let src = (row * 4 + col) * 4
                        rgba[dst * 4 + 0] = texelsRGBA[src + 0]
                        rgba[dst * 4 + 1] = texelsRGBA[src + 1]
                        rgba[dst * 4 + 2] = texelsRGBA[src + 2]
                        rgba[dst * 4 + 3] = texelsRGBA[src + 3]
                    }
                }
            }
        }
    }
    if isHalf {
        result = halves.withUnsafeBufferPointer { src in
            [UInt8](UnsafeRawBufferPointer(src).map { $0 })
        }
    } else {
        result = rgba
    }
    return result
}

var failures = 0
func compare(name: String, cpu: [UInt8], gpu: [UInt8], kind: FormatKind) {
    guard cpu.count == gpu.count else {
        print("FAIL \(name): size \(cpu.count) vs \(gpu.count)")
        failures += 1
        return
    }
    // bcdec's precise BC4/5 path writes only the meaningful channel bytes, while
    // the GPU kernels fill a full uchar4; compare only those channels.
    let masked = (kind == .bc4 || kind == .bc5)
    var mismatches = 0
    var first: (Int, UInt8, UInt8)?
    for i in 0..<cpu.count where cpu[i] != gpu[i] {
        if masked {
            let channel = i % 4
            if (kind == .bc4 && channel != 0) || (kind == .bc5 && channel > 1) {
                continue
            }
        }
        if first == nil { first = (i, cpu[i], gpu[i]) }
        mismatches += 1
    }
    if mismatches == 0 {
        print("PASS \(name)")
    } else {
        print("FAIL \(name): \(mismatches)/\(cpu.count) bytes differ; first at \(first!.0): cpu \(first!.1) gpu \(first!.2)")
        failures += 1
    }
}

for testCase in cases {
    let width = 16
    let height = 16
    let blockCount = 16
    var blocks = [UInt8](repeating: 0, count: blockCount * testCase.blockSize)
    var rng = SeededRandom(seed: 0xABCD1234)
    for i in 0..<blocks.count { blocks[i] = rng.byte() }
    for i in 0..<testCase.modeFirstBytes.count {
        blocks[i * testCase.blockSize] = testCase.modeFirstBytes[i]
    }
    let bytesPerPixel = testCase.kind == .bc6h ? 8 : 4
    let gpu = decodeGPURun(kernel: testCase.kernel,
                           blocks: blocks,
                           signed: testCase.signed,
                           width: width,
                           height: height,
                           bytesPerPixel: bytesPerPixel)
        let cpu = decodeCPU(kind: testCase.kind,
                            signed: testCase.signed,
                            blocks: blocks,
                            width: width,
                            height: height,
                            blockSize: testCase.blockSize)
    compare(name: testCase.name, cpu: cpu, gpu: gpu, kind: testCase.kind)
}

// BC6H across all mode values.
let modeValues: [UInt8] = [0, 1, 2, 3, 6, 7, 10, 11, 14, 15, 18, 19, 22, 23, 26, 27, 30, 31]
for value in modeValues {
    for signed in [false, true] {
        let label = "BC6H mode \(value)\(signed ? " signed" : "")"
        let width = 16
        let height = 16
        var blocks = [UInt8](repeating: 0, count: 16 * 16)
        var rng = SeededRandom(seed: UInt64(value) &* 7919 &+ (signed ? 104729 : 5))
        for i in 0..<blocks.count { blocks[i] = rng.byte() }
        blocks[0] = value
        let gpu = decodeGPURun(kernel: "mb_bc6h_decode", blocks: blocks, signed: signed, width: width, height: height, bytesPerPixel: 8)
        let cpu = decodeCPU(kind: .bc6h, signed: signed, blocks: blocks, width: width, height: height, blockSize: 16)
        compare(name: label, cpu: cpu, gpu: gpu, kind: .bc6h)
    }
}

// Repeat the byte-format sweep with several random seeds for deeper coverage.
for seed in 1...4 {
    for testCase in cases {
        let width = 32
        let height = 32
        let blockCount = 64
        var blocks = [UInt8](repeating: 0, count: blockCount * testCase.blockSize)
        var rng = SeededRandom(seed: UInt64(seed) &* 1_000_003 &+ UInt64(testCase.blockSize))
        for i in 0..<blocks.count { blocks[i] = rng.byte() }
        for i in 0..<testCase.modeFirstBytes.count {
            blocks[i * testCase.blockSize] = testCase.modeFirstBytes[i]
        }
        let bytesPerPixel = testCase.kind == .bc6h ? 8 : 4
        let gpu = decodeGPURun(kernel: testCase.kernel, blocks: blocks, signed: testCase.signed, width: width, height: height, bytesPerPixel: bytesPerPixel)
        let cpu = decodeCPU(kind: testCase.kind, signed: testCase.signed, blocks: blocks, width: width, height: height, blockSize: testCase.blockSize)
        compare(name: "\(testCase.name) seed \(seed) 32x32", cpu: cpu, gpu: gpu, kind: testCase.kind)
    }
}

if failures == 0 {
    print("ALL BC DIFFERENTIAL TESTS PASSED")
} else {
    print("\(failures) test group(s) FAILED")
    exit(1)
}
