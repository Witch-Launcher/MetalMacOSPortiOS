import Foundation
import Metal

// Facade driver: exercises the MetalBridge facade end-to-end on the macOS host.
// Built by Tools/FacadeDriver/build_and_run.sh; every test is a real Metal
// operation through the same Swift sources the iOS build uses.

let facade: MacMetalDevice
do {
    guard let device = MTLCreateSystemDefaultDevice() else {
        fail("no Metal device")
    }
    facade = try MacMetalDevice(device: device)
    print("device: \(facade.capabilities.deviceName)")
} catch {
    fail("facade init failed: \(error)")
}

func run(_ name: String, _ body: () throws -> Void) throws {
    try body()
    print("PASS \(name)")
}

func fail(_ message: String) -> Never {
    print("FACADE-TEST FAIL: \(message)")
    exit(1)
}

// MARK: - Fixtures

/// BC1 block: c0=0x0000 black, c1=0xFFFF, all indices 0 -> every texel (0,0,0,255).
let bc1BlackBlock: [UInt8] = [0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00]

/// BC7 harness block 0: mode 0, endpoints (8,156,255)/(222,123,156); texel 0 is
/// subset 1's fixup with 2-bit index 1 -> weight 9 -> (38,151,241,255).
let bc7FixtureBlock: [UInt8] = [0x01, 0x1A, 0xFA, 0x25, 0xCF, 0x06, 0xFA, 0xD3,
                                0xE8, 0xED, 0xAA, 0xD7, 0x74, 0xFE, 0x6D, 0x8F]

func repeatBlocks(_ block: [UInt8], count: Int) -> Data {
    var data = Data()
    for _ in 0..<count { data.append(block, count: block.count) }
    return data
}

func texelString(_ bytes: [UInt8]) -> String {
    (0..<(bytes.count / 4)).map { texel in
        let at = texel * 4
        return "\(bytes[at]),\(bytes[at + 1]),\(bytes[at + 2]),\(bytes[at + 3])"
    }.joined(separator: " ")
}

do {
    // 1. BC1 through the facade's makeTexture route ------------------------------------
    try run("1 BC1 decode via facade, 16 texels black") {
        let result = try facade.makeTexture(rawData: repeatBlocks(bc1BlackBlock, count: 3),
                                            pixelFormat: MTLPixelFormat(rawValue: 130)!,
                                            width: 4,
                                            height: 4,
                                            usage: [.shaderRead, .shaderWrite])
        XCTAssertEqual(result.isDecoded, true)
        XCTAssertEqual(result.texture.pixelFormat, MTLPixelFormat.rgba8Unorm)
        var bytes = [UInt8](repeating: 0xEE, count: 16 * 4)
        try result.texture.getBytes(&bytes, bytesPerRow: 16, bytesPerImage: 0,
                                    from: MTLRegionMake3D(0, 0, 0, 4, 4, 1),
                                    mipmapLevel: 0, slice: 0)
        for texel in 0..<16 {
            let at = texel * 4
            XCTAssertEqual(bytes[at], 0, "texel \(texel) R")
            XCTAssertEqual(bytes[at + 1], 0, "texel \(texel) G")
            XCTAssertEqual(bytes[at + 2], 0, "texel \(texel) B")
            XCTAssertEqual(bytes[at + 3], 255, "texel \(texel) A")
        }
        print("   decodeMip output: \(texelString(Array(bytes[0..<16])))")
    }

    // 1b. decodeMip directly into a plain 4x4 texture -----------------------------------
    try run("1b BCDecoder.decodeMip into plain 4x4") {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 4
        descriptor.height = 4
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = unwrap(facade.device.makeTexture(descriptor: descriptor), "no texture")
        try facade.bcDecode.decodeMip(Data(bc1BlackBlock),
                                      format: .bc1rgba,
                                      width: 4,
                                      height: 4,
                                      into: texture,
                                      mipLevel: 0)
        var bytes = [UInt8](repeating: 0, count: 16 * 4)
        try texture.getBytes(&bytes, bytesPerRow: 16, bytesPerImage: 0,
                             from: MTLRegionMake3D(0, 0, 0, 4, 4, 1),
                             mipmapLevel: 0, slice: 0)
        for texel in 0..<16 {
            XCTAssertEqual(bytes[texel * 4 + 3], 255, "texel \(texel) alpha")
        }
        print("   decodeMip output: \(texelString(bytes))")
    }

    // 1c. Mip dump of the facade-decoded 4x4 chain --------------------------------------
    try run("1c mip dump of decoded chain") {
        let result = try facade.makeTexture(rawData: repeatBlocks(bc1BlackBlock, count: 3),
                                            pixelFormat: MTLPixelFormat(rawValue: 130)!,
                                            width: 4,
                                            height: 4,
                                            usage: [.shaderRead, .shaderWrite])
        XCTAssertEqual(result.texture.mipmapLevelCount, 3)
        var w = 4
        for level in 0..<3 {
            var bytes = [UInt8](repeating: 0, count: w * w * 4)
            try result.texture.getBytes(&bytes, bytesPerRow: w * 4, bytesPerImage: 0,
                                        from: MTLRegionMake3D(0, 0, 0, w, w, 1),
                                        mipmapLevel: level, slice: 0)
            print("   mip\(level) (\(w)x\(w)): \(texelString(bytes))")
            w = max(1, w >> 1)
        }
    }

    // 2. BC7 mip chain through the facade -----------------------------------------------
    try run("2 BC7 mip chain (5 levels), texel 0 = 38,151,241,255") {
        // 16x16 mip chain has 23 blocks (16, 4, 1, 1, 1).
        let result = try facade.makeTexture(rawData: repeatBlocks(bc7FixtureBlock, count: 23),
                                            pixelFormat: MTLPixelFormat(rawValue: 142)!,
                                            width: 16,
                                            height: 16)
        XCTAssertEqual(result.isDecoded, true)
        XCTAssertEqual(result.texture.mipmapLevelCount, 5)
        var bytes = [UInt8](repeating: 0, count: 16 * 4)
        try result.texture.getBytes(&bytes, bytesPerRow: 16, bytesPerImage: 0,
                                    from: MTLRegionMake3D(0, 0, 0, 1, 1, 1),
                                    mipmapLevel: 0, slice: 0)
        XCTAssertEqual(bytes[0], 38, "texel 0 R")
        XCTAssertEqual(bytes[1], 151, "texel 0 G")
        XCTAssertEqual(bytes[2], 241, "texel 0 B")
        XCTAssertEqual(bytes[3], 255, "texel 0 A")
    }

    // 3. Native path: managed -> shared, no decode --------------------------------------
    try run("3 native path keeps managed->shared conversion") {
        let result = try facade.makeTexture(rawData: Data(),
                                            pixelFormat: .rgba8Unorm,
                                            width: 8,
                                            height: 8,
                                            usage: [.shaderRead],
                                            macStorageMode: .managed)
        XCTAssertEqual(result.isDecoded, false)
        XCTAssertEqual(result.texture.pixelFormat, MTLPixelFormat.rgba8Unorm)
        XCTAssertEqual(result.texture.storageMode, MTLStorageMode.shared)
    }

    // 4. BC1 decoded then blitted into private storage -----------------------------------
    try run("4 BC1 decoded then blitted into private storage") {
        let result = try facade.makeTexture(rawData: repeatBlocks(bc1BlackBlock, count: 3),
                                            pixelFormat: MTLPixelFormat(rawValue: 130)!,
                                            width: 4,
                                            height: 4,
                                            usage: [.shaderRead],
                                            macStorageMode: .privateMode)
        XCTAssertEqual(result.isDecoded, true)
        XCTAssertEqual(result.texture.storageMode, MTLStorageMode.private)
    }

    // 5. Memoryless BC payload rejected ---------------------------------------------------
    try run("5 memoryless BC payload rejected as unsupported") {
        do {
            _ = try facade.makeTexture(rawData: repeatBlocks(bc1BlackBlock, count: 3),
                                       pixelFormat: MTLPixelFormat(rawValue: 130)!,
                                       width: 4,
                                       height: 4,
                                       macStorageMode: .memoryless)
            fail("memoryless BC payload must throw")
        } catch BridgeError.unsupported {
            // expected
        }
    }

    // 6. Full 32x32 BC1 mip chain ---------------------------------------------------------
    try run("6 32x32 BC1 full mip chain decoded; last mip alpha 255") {
        // Mip chain 32,16,8,4,2,1 -> block counts 64,16,4,1,1,1 = 87 blocks.
        let result = try facade.makeTexture(rawData: repeatBlocks(bc1BlackBlock, count: 87),
                                            pixelFormat: MTLPixelFormat(rawValue: 130)!,
                                            width: 32,
                                            height: 32,
                                            usage: [.shaderRead, .shaderWrite])
        XCTAssertEqual(result.isDecoded, true)
        XCTAssertEqual(result.texture.mipmapLevelCount, 6)
        var last = [UInt8](repeating: 0, count: 4)
        try result.texture.getBytes(&last, bytesPerRow: 4, bytesPerImage: 0,
                                    from: MTLRegionMake3D(0, 0, 0, 1, 1, 1),
                                    mipmapLevel: 5, slice: 0)
        XCTAssertEqual(last[3], 255, "last mip alpha")
        XCTAssertEqual(last[0], 0, "last mip R")
    }

    // 7. FenceBridge CPU path ------------------------------------------------------------------
    try run("7 FenceBridge signal/notify/wait") {
        let event = facade.fences.makeEvent(label: "host")
        XCTAssertEqual(event.signaledValue, 0)
        event.signal(5)
        XCTAssertEqual(event.signaledValue, 5)
        event.signal(2) // at-or-below ignored
        XCTAssertEqual(event.signaledValue, 5)
        var fired = 0
        event.notify(atValue: 5) { fired += 1 }
        facade.fences.notificationQueue.sync {}
        XCTAssertEqual(fired, 1, "notify for a past value fires once, async")
        let timedOut = event.wait(untilValue: 9, timeout: 0.05)
        XCTAssertEqual(timedOut, false)
        event.signal(9)
        XCTAssertEqual(event.wait(untilValue: 9, timeout: 1), true)
        print("   pass 7 ok (signaledValue monotonic, notify, wait)")
    }

    // 8. SparseFallback page model -------------------------------------------------------------
    try run("8 SparseFallback pages, zeros, mapping event") {
        let texture = try facade.sparse!.makeTexture(pixelFormat: .rgba8Unorm, width: 128, height: 128)
        XCTAssertEqual(texture.tileSide, 64, "sqrt(16384/4) = 64 texels per page side")
        XCTAssertEqual(texture.pagesWide(mipLevel: 0), 2)
        XCTAssertEqual(texture.pagesHigh(mipLevel: 0), 2)
        var bytes = [UInt8](repeating: 0xEE, count: 128 * 128 * 4)
        try texture.texture.getBytes(&bytes, bytesPerRow: 128 * 4, bytesPerImage: 0,
                                     from: MTLRegionMake3D(0, 0, 0, 128, 128, 1), mipmapLevel: 0, slice: 0)
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 }, "fresh sparse fallback reads as zeros")
        let start = texture.mappingChangedEvent.signaledValue
        try texture.allocate([SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0)])
        XCTAssertEqual(texture.mappingChangedEvent.signaledValue, start + 1)
        var pattern = [UInt8](repeating: 0xAB, count: 64 * 64 * 4)
        try texture.texture.replace(region: MTLRegionMake2D(0, 0, 64, 64),
                                    mipmapLevel: 0,
                                    withBytes: &pattern,
                                    bytesPerRow: 64 * 4)
        try texture.deallocate([SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0)])
        var after = [UInt8](repeating: 0xEE, count: 64 * 64 * 4)
        try texture.texture.getBytes(&after, bytesPerRow: 64 * 4, bytesPerImage: 0,
                                     from: MTLRegionMake3D(0, 0, 0, 64, 64, 1), mipmapLevel: 0, slice: 0)
        XCTAssertTrue(after.allSatisfy { $0 == 0 }, "deallocated pages must read as zeros")
        print("   pass 8 ok (tileSide=64, zeros on dealloc, event advances)")
    }

    // 9. ArgumentReplayEncoder: replayed bindings reach a real compute encoder ------------------
    try run("9 ArgumentReplayEncoder replay reaches compute encoder") {
        let device = facade.device
        let blocksBuffer = unwrap(device.makeBuffer(bytes: bc1BlackBlock, length: 8, options: .storageModeShared), "no blocks buffer")
        let outputBuffer = unwrap(device.makeBuffer(length: 16 * 4 * 2, options: .storageModeShared), "no output buffer")
        memset(outputBuffer.contents(), 0xEE, 16 * 4 * 2)
        var params = BCParamsLayout()
        params.widthPixels = 8
        params.heightPixels = 4
        let paramsBuffer = unwrap(device.makeBuffer(bytes: &params, length: MemoryLayout<BCParamsLayout>.size, options: .storageModeShared), "no params buffer")

        let replay = ArgumentReplayEncoder()
        XCTAssertEqual(replay.count, 0)
        replay.encodeSetBuffer(blocksBuffer, offset: 0, index: 0)
        replay.encodeSetBuffer(outputBuffer, offset: 0, index: 1)
        replay.encodeSetBuffer(paramsBuffer, offset: 0, index: 2)
        XCTAssertEqual(replay.count, 3)
        replay.encodeSetBytes(Data([1, 2, 3, 4]), index: 7)
        XCTAssertEqual(replay.count, 4)
        replay.clear()
        XCTAssertEqual(replay.count, 0)
        replay.encodeSetBuffer(blocksBuffer, offset: 0, index: 0)
        replay.encodeSetBuffer(outputBuffer, offset: 0, index: 1)
        replay.encodeSetBuffer(paramsBuffer, offset: 0, index: 2)

        let lib = unwrap(try? device.makeDefaultLibrary(bundle: Bundle.main), "no default library")
        let fn = unwrap(lib.makeFunction(name: "mb_bc1_decode"), "no mb_bc1_decode")
        let pipeline = try device.makeComputePipelineState(function: fn)
        let queue = try facade.makeCommandQueue()
        let cb = unwrap(queue.makeCommandBuffer(), "no command buffer")
        let enc = unwrap(cb.makeComputeCommandEncoder(), "no encoder")
        enc.setComputePipelineState(pipeline)
        replay.replay(into: enc)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { fail("replay command buffer failed: \(e)") }
        let out = outputBuffer.contents().bindMemory(to: UInt8.self, capacity: 128)
        let written = [0, 1, 2, 3, 8, 9, 10, 11, 16, 17, 18, 19, 24, 25, 26, 27]
        for texel in 0..<32 {
            if written.contains(texel) {
                if out[texel * 4 + 3] != 255 { fail("replayed texel \(texel) alpha \(out[texel*4+3])") }
            } else if out[texel * 4] != 0xEE {
                fail("texel \(texel) written despite pitch 8")
            }
        }
        print("   pass 9 ok (pitch-8 params reached the kernel through replay)")
    }

    // 10. ServiceProbes bundle (the Lab's Service Probes section) ------------------------------
    try run("10 ServiceProbes.run() all services") {
        let results = ServiceProbes.run(device: facade.device)
        for result in results {
            print("   \(result.name): \(result.passed ? "PASS" : "FAIL") \(result.detail)")
        }
        XCTAssertTrue(results.allSatisfy { $0.passed }, "every service probe must pass")
        print("   pass 10 ok (\(results.count) probes)")
    }

    print("ALL FACADE TESTS PASSED")
} catch {
    fail("unexpected top-level error: \(error)")
}

func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if a != b { fail("assert \(a) != \(b) \(message) (file \(file) line \(line))") }
}
func XCTAssertTrue(_ cond: Bool, _ message: String = "") {
    if !cond { fail("assert true failed \(message)") }
}
func unwrap<T>(_ value: T?, _ message: String) -> T {
    guard let value = value else { fail(message) }
    return value
}
