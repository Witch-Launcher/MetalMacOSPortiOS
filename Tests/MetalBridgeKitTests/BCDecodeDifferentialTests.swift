import XCTest
import Metal
@testable import MetalBridgeKit

final class BCDecodeDifferentialTests: XCTestCase {
    private var device: MTLDevice!
    private var decoder: BCDecoder!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        self.device = device
        self.decoder = BCDecoder(device: device)
    }

    // Deterministic xorshift so failures reproduce exactly.
    private struct SeededRandom {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next() & 0xFF) }
    }

    private enum FormatKind {
        case bc1, bc2, bc3, bc4, bc5, bc6h, bc7
    }

    private func pixelBytes(kind: FormatKind) -> Int {
        kind == .bc6h ? 8 : 4 // half4 vs uchar4
    }

    private func decodeOnCPU(kind: FormatKind, signed: Bool, blocks: [UInt8], width: Int, height: Int) -> [UInt8] {
        let blocksWide = (width + 3) / 4
        let blocksHigh = (height + 3) / 4
        let bytesPerPixel = kind == .bc6h ? 8 : 4
        var result = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        if kind == .bc6h {
            // CPU result is laid out as half4 (RGBA, 8 bytes per pixel) to match the
            // GPU staging output; bcdec writes RGB halves per texel.
            var halves = [UInt16](repeating: 0, count: width * height * 3)
            for by in 0..<blocksHigh {
                for bx in 0..<blocksWide {
                    let blockIndex = (by * blocksWide + bx) * 16
                    var block = [UInt8](repeating: 0, count: 16)
                    withUnsafeMutableBytes(of: &block) { raw in
                        for i in 0..<16 { raw[i] = blocks[blockIndex + i] }
                    }
                    var texels = [UInt16](repeating: 0, count: 16 * 3)
                    bcdec_bc6h_half(block, &texels, 4 * 3, signed ? 1 : 0)
                    for row in 0..<4 {
                        for col in 0..<4 {
                            let src = row * 12 + col * 3
                            let x = bx * 4 + col
                            let y = by * 4 + row
                            let dst = (y * width + x) * 3
                            if x < width, y < height {
                                halves[dst + 0] = texels[src + 0]
                                halves[dst + 1] = texels[src + 1]
                                halves[dst + 2] = texels[src + 2]
                            }
                        }
                    }
                }
            }
            var rgba = [UInt16](repeating: 0x3C00, count: width * height * 4)
            for pixel in 0..<(width * height) {
                rgba[pixel * 4 + 0] = halves[pixel * 3 + 0]
                rgba[pixel * 4 + 1] = halves[pixel * 3 + 1]
                rgba[pixel * 4 + 2] = halves[pixel * 3 + 2]
            }
            rgba.withUnsafeBufferPointer { src in
                result.withUnsafeMutableBytes { dest in
                    memcpy(dest.baseAddress, src.baseAddress, min(dest.count, width * height * 8))
                }
            }
            return result
        }
        // BC1-5, BC7 decode into 4-byte RGBA pixels with a 4-byte pitch between rows.
        let blockSize = kind == .bc1 || kind == .bc4 ? 8 : (kind == .bc5 ? 16 : (kind == .bc7 ? 16 : 16))
        var rgb = [UInt8](repeating: 0, count: width * height * 4)
        for by in 0..<blocksHigh {
            for bx in 0..<blocksWide {
                let blockIndex = (by * blocksWide + bx) * blockSize
                var block = [UInt8](repeating: 0, count: blockSize)
                withUnsafeMutableBytes(of: &block) { raw in
                    for i in 0..<blockSize { raw[i] = blocks[blockIndex + i] }
                }
                var texels = [UInt8](repeating: 0, count: 16 * 4)
                switch kind {
                case .bc1:
                    bcdec_bc1(block, &texels, 4)
                case .bc2:
                    bcdec_bc2(block, &texels, 4)
                case .bc3:
                    bcdec_bc3(block, &texels, 4)
                case .bc4:
                    bcdec_bc4(block, &texels, 4, signed ? 1 : 0)
                case .bc5:
                    bcdec_bc5(block, &texels, 4, signed ? 1 : 0)
                case .bc7:
                    bcdec_bc7(block, &texels, 4)
                default:
                    fatalError("unreachable")
                }
                for row in 0..<4 {
                    for col in 0..<4 {
                        let x = bx * 4 + col
                        let y = by * 4 + row
                        if x < width, y < height {
                            let src = (row * 4 + col) * 4
                            let dst = (y * width + x) * 4
                            rgb[dst + 0] = texels[src + 0]
                            rgb[dst + 1] = texels[src + 1]
                            rgb[dst + 2] = texels[src + 2]
                            rgb[dst + 3] = texels[src + 3]
                        }
                    }
                }
            }
        }
        // Expand RGB into the staging layout the GPU comparison expects.
        for y in 0..<height {
            for x in 0..<width {
                let src = (y * width + x) * 4
                let dst = (y * width + x) * 4
                result[dst + 0] = rgb[src + 0]
                result[dst + 1] = rgb[src + 1]
                result[dst + 2] = rgb[src + 2]
                result[dst + 3] = rgb[src + 3]
            }
        }
        return result
    }

    private func decodeOnGPU(kind: FormatKind, format: BCDecoder.Format, blocks: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format.outputPixelFormat,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        try decoder.decodeMip(Data(blocks), format: format, width: width, height: height, into: texture, mipLevel: 0)
        var out = [UInt8](repeating: 0, count: width * height * pixelBytes(kind: kind))
        texture.getBytes(&out,
                         bytesPerRow: width * pixelBytes(kind: kind),
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
        return out
    }

    private func runDifferential(kind: FormatKind, format: BCDecoder.Format, modeFirstBytes: [UInt8], signed: Bool = false, line: UInt = #line) throws {
        let width = 16
        let height = 16
        let blocksWide = (width + 3) / 4
        let blocksHigh = (height + 3) / 4
        let blockCount = blocksWide * blocksHigh
        let blockSize = format.blockSize

        // Cover the requested mode bytes in the first blocks, random elsewhere.
        var blocks = [UInt8](repeating: 0, count: blockCount * blockSize)
        var rng = SeededRandom(state: UInt64(line) &* 0x9E3779B97F4A7C15)
        for index in 0..<blockCount {
            for byteIndex in 0..<blockSize {
                blocks[index * blockSize + byteIndex] = rng.byte()
            }
            if index < modeFirstBytes.count {
                blocks[index * blockSize] = modeFirstBytes[index]
            }
        }

        let cpu = decodeOnCPU(kind: kind, signed: signed, blocks: blocks, width: width, height: height)
        let gpu = try decodeOnGPU(kind: kind, format: format, blocks: blocks, width: width, height: height)

        var mismatches = 0
        var firstMismatch: (Int, UInt8, UInt8)?
        for i in 0..<min(cpu.count, gpu.count) where cpu[i] != gpu[i] {
            if mismatches == 0 { firstMismatch = (i, cpu[i], gpu[i]) }
            mismatches += 1
        }
        XCTAssertEqual(mismatches, 0,
                       "GPU decode diverges from bcdec for \(format): \(mismatches) byte mismatches; first at \(String(describing: firstMismatch))")
    }

    func testBC1MatchesBCDec() throws {
        try runDifferential(kind: .bc1, format: .bc1rgba, modeFirstBytes: [0xFF, 0xFE, 0x00])
    }

    func testBC2MatchesBCDec() throws {
        try runDifferential(kind: .bc2, format: .bc2rgba, modeFirstBytes: [])
    }

    func testBC3MatchesBCDec() throws {
        try runDifferential(kind: .bc3, format: .bc3rgba, modeFirstBytes: [0xFF, 0xFE, 0x00])
    }

    func testBC4UnormMatchesBCDec() throws {
        try runDifferential(kind: .bc4, format: .bc4rUnorm, modeFirstBytes: [0xFF, 0xFE, 0x00])
    }

    func testBC4SnormMatchesBCDec() throws {
        try runDifferential(kind: .bc4, format: .bc4rSnorm, modeFirstBytes: [0xFF, 0xFE, 0x00], signed: true)
    }

    func testBC5UnormMatchesBCDec() throws {
        try runDifferential(kind: .bc5, format: .bc5rgUnorm, modeFirstBytes: [0xFF, 0xFE, 0x00])
    }

    func testBC5SnormMatchesBCDec() throws {
        try runDifferential(kind: .bc5, format: .bc5rgSnorm, modeFirstBytes: [0xFF, 0xFE, 0x00], signed: true)
    }

    func testBC7AllModesMatchBCDec() throws {
        // Byte0 values: one zero bit then a 1 at the mode position (0x01 = mode 0 ... 0x80 = mode 7).
        try runDifferential(kind: .bc7,
                            format: .bc7rgbaUnorm,
                            modeFirstBytes: [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x00])
    }

    func testBC6HAllModesMatchBCDec() throws {
        // The low 5 bits of byte0 are the mode value: 0/1 two-bit modes, the rest
        // five-bit (two-region 2,6..30; one-region 3,7,11,15; reserved 19..31).
        let modeValues: [UInt8] = [0, 1, 2, 3, 6, 7, 10, 11, 14, 15, 18, 19, 22, 23, 26, 27, 30, 31]
        for value in modeValues {
            try runDifferential(kind: .bc6h, format: .bc6hrgbuFloat, modeFirstBytes: [value])
        }
    }

    func testBC6HSignedMatchesBCDec() throws {
        try runDifferential(kind: .bc6h, format: .bc6hrgbFloat, modeFirstBytes: [0, 2, 10, 30, 3, 7, 11, 15], signed: true)
    }

    func testFullMipChainDecodeMatchesBCDecPerMip() throws {
        // BC1, 16x16 with mips; decode the whole chain through the public API and
        // verify the largest level against the CPU decoder.
        let width = 16
        let height = 16
        let blocks = 4 * 4
        var data = [UInt8](repeating: 0, count: blocks * 8)
        var rng = SeededRandom(state: 0xDEADBEEF)
        for i in 0..<data.count { data[i] = rng.byte() }
        // Add higher-mip payloads so the API's size check passes.
        var mip = 1
        var w = 8
        var h = 8
        while w >= 4 && h >= 4 {
            data += [UInt8](repeating: rng.byte(), count: ((w + 3) / 4) * ((h + 3) / 4) * 8)
            w >>= 1
            h >>= 1
            mip += 1
        }
        let texture = try decoder.decodeTexture(rawData: Data(data), format: .bc1rgba, width: width, height: height)
        XCTAssertEqual(texture.mipmapLevelCount, mip)

        let cpu = decodeOnCPU(kind: .bc1, signed: false, blocks: Array(data[0..<(blocks * 8)]), width: width, height: height)
        var gpu = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&gpu,
                         bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
        XCTAssertEqual(cpu, gpu)
    }

    func testMalformedPayloadFailsClearly() throws {
        XCTAssertThrowsError(try decoder.decodeTexture(rawData: Data([0]),
                                                       format: .bc3rgba,
                                                       width: 8,
                                                       height: 8)) { error in
            guard let decodeError = error as? BCDecoder.DecodeError else {
                return XCTFail("Expected DecodeError, got \(error)")
            }
            XCTAssertTrue(decodeError.message.contains("too small"), decodeError.message)
        }
        XCTAssertThrowsError(try decoder.decodeTexture(rawData: Data(),
                                                       format: .bc3rgba,
                                                       width: 7,
                                                       height: 8)) { error in
            guard let decodeError = error as? BCDecoder.DecodeError else {
                return XCTFail("Expected DecodeError, got \(error)")
            }
            XCTAssertTrue(decodeError.message.contains("multiples of 4"), decodeError.message)
        }
    }
}
