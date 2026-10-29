import Foundation
import Metal

/// One emulation-service probe result for the Lab and test harnesses.
public struct ServiceProbeResult {
    public let name: String
    public let passed: Bool
    public let detail: String
}

/// Runs the emulation services end-to-end on real Metal so the Lab (and the
/// host facade driver) can report what actually works on this device.
public enum ServiceProbes {
    public static func run(device: MTLDevice? = nil) -> [ServiceProbeResult] {
        guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
            return [ServiceProbeResult(name: "Services", passed: false, detail: "No Metal device.")]
        }
        let facade: MacMetalDevice
        do {
            facade = try MacMetalDevice(device: resolved)
        } catch {
            return [ServiceProbeResult(name: "Services", passed: false,
                                       detail: "Facade init failed: \(error.localizedDescription)")]
        }
        return [
            bc1DecodeProbe(facade),
            bc7DecodeProbe(facade),
            fenceProbe(facade),
            sparseProbe(facade),
            replayProbe(facade),
        ]
    }

    // MARK: - BC decode

    /// BC1 block: c0=0x0000 black, c1=0xFFFF, all indices 0 -> every texel (0,0,0,255).
    private static let bc1BlackBlock: [UInt8] = [0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00]

    private static func makeSharedTexture(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BCDecoder.DecodeError(message: "Texture creation returned nil.")
        }
        return texture
    }

    private static func bc1DecodeProbe(_ facade: MacMetalDevice) -> ServiceProbeResult {
        do {
            let texture = try makeSharedTexture(facade.device, width: 4, height: 4)
            try facade.bcDecode.decodeMip(Data(bc1BlackBlock),
                                          format: .bc1rgba,
                                          width: 4,
                                          height: 4,
                                          into: texture,
                                          mipLevel: 0)
            var bytes = [UInt8](repeating: 0xEE, count: 16 * 4)
            try texture.getBytes(&bytes,
                                 bytesPerRow: 16,
                                 bytesPerImage: 0,
                                 from: MTLRegionMake3D(0, 0, 0, 4, 4, 1),
                                 mipmapLevel: 0,
                                 slice: 0)
            let wrong = bytes.enumerated().filter { $0.offset % 4 == 0 && $0.element != 0 }
                .count + bytes.enumerated().filter { $0.offset % 4 == 3 && $0.element != 255 }.count
            if wrong == 0 {
                return ServiceProbeResult(name: "BC1 decode", passed: true,
                                          detail: "4x4 block decoded to 16 black opaque texels.")
            }
            return ServiceProbeResult(name: "BC1 decode", passed: false,
                                      detail: "\(wrong) texel channels wrong.")
        } catch {
            return ServiceProbeResult(name: "BC1 decode", passed: false,
                                      detail: "\(error.localizedDescription)")
        }
    }

    private static func bc7DecodeProbe(_ facade: MacMetalDevice) -> ServiceProbeResult {
        // Harness block 0: mode 0, endpoints (8,156,255)/(222,123,156); texel 0 is
        // subset 1's fixup with 2-bit index 1 -> weight 9 -> (38,151,241,255).
        let block: [UInt8] = [0x01, 0x1A, 0xFA, 0x25, 0xCF, 0x06, 0xFA, 0xD3,
                              0xE8, 0xED, 0xAA, 0xD7, 0x74, 0xFE, 0x6D, 0x8F]
        do {
            let texture = try makeSharedTexture(facade.device, width: 4, height: 4)
            try facade.bcDecode.decodeMip(Data(block),
                                          format: .bc7rgbaUnorm,
                                          width: 4,
                                          height: 4,
                                          into: texture,
                                          mipLevel: 0)
            var bytes = [UInt8](repeating: 0, count: 16)
            try texture.getBytes(&bytes,
                                 bytesPerRow: 16,
                                 bytesPerImage: 0,
                                 from: MTLRegionMake3D(0, 0, 0, 1, 1, 1),
                                 mipmapLevel: 0,
                                 slice: 0)
            if bytes[0] == 38, bytes[1] == 151, bytes[2] == 241, bytes[3] == 255 {
                return ServiceProbeResult(name: "BC7 decode", passed: true,
                                          detail: "Texel 0 = (38,151,241,255), matching bcdec.")
            }
            return ServiceProbeResult(name: "BC7 decode", passed: false,
                                      detail: "Texel 0 = (\(bytes[0]),\(bytes[1]),\(bytes[2]),\(bytes[3])).")
        } catch {
            return ServiceProbeResult(name: "BC7 decode", passed: false,
                                      detail: "\(error.localizedDescription)")
        }
    }

    // MARK: - Fences

    private static func fenceProbe(_ facade: MacMetalDevice) -> ServiceProbeResult {
        let event = facade.fences.makeEvent(label: "probe.fence")
        event.signal(3)
        event.signal(2) // at-or-below is ignored
        let monotonic = event.signaledValue == 3
        var fired = 0
        event.notify(atValue: 3) { fired += 1 }
        facade.fences.notificationQueue.sync {}
        let notifyOK = fired == 1
        let waitOK = !event.wait(untilValue: 99, timeout: 0.05) && event.wait(untilValue: 3, timeout: 1)
        if monotonic, notifyOK, waitOK {
            return ServiceProbeResult(name: "Fences", passed: true,
                                      detail: "Monotonic signal, one-shot notify, wait semantics.")
        }
        return ServiceProbeResult(name: "Fences", passed: false,
                                  detail: "monotonic=\(monotonic) notify=\(fired) wait=\(waitOK).")
    }

    // MARK: - Sparse

    private static func sparseProbe(_ facade: MacMetalDevice) -> ServiceProbeResult {
        do {
            let sparse = try facade.sparse.makeTexture(pixelFormat: .rgba8Unorm,
                                                       width: 128,
                                                       height: 128)
            let tileSideOK = sparse.tileSide == 64
            let gridOK = sparse.pagesWide(mipLevel: 0) == 2 && sparse.pagesHigh(mipLevel: 0) == 2
            var bytes = [UInt8](repeating: 0xEE, count: 64 * 64 * 4)
            try sparse.texture.getBytes(&bytes,
                                        bytesPerRow: 64 * 4,
                                        bytesPerImage: 0,
                                        from: MTLRegionMake3D(0, 0, 0, 64, 64, 1),
                                        mipmapLevel: 0,
                                        slice: 0)
            let zerosOK = bytes.allSatisfy { $0 == 0 }
            let start = sparse.mappingChangedEvent.signaledValue
            try sparse.allocate([SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0)])
            let eventOK = sparse.mappingChangedEvent.signaledValue == start + 1
            try sparse.deallocate([SparseTexture.Page(mipLevel: 0, pageX: 0, pageY: 0)])
            try sparse.texture.getBytes(&bytes,
                                        bytesPerRow: 64 * 4,
                                        bytesPerImage: 0,
                                        from: MTLRegionMake3D(0, 0, 0, 64, 64, 1),
                                        mipmapLevel: 0,
                                        slice: 0)
            let zeroedOK = bytes.allSatisfy { $0 == 0 }
            if tileSideOK, gridOK, zerosOK, eventOK, zeroedOK {
                return ServiceProbeResult(name: "Sparse textures", passed: true,
                                          detail: "64-texel pages, zero-filled backing, mapping event.")
            }
            return ServiceProbeResult(name: "Sparse textures", passed: false,
                                      detail: "tileSide=\(sparse.tileSide) gridOK=\(gridOK) zeros=\(zerosOK) event=\(eventOK) zeroed=\(zeroedOK).")
        } catch {
            return ServiceProbeResult(name: "Sparse textures", passed: false,
                                      detail: "\(error.localizedDescription)")
        }
    }

    // MARK: - Argument replay

    private static func replayProbe(_ facade: MacMetalDevice) -> ServiceProbeResult {
        do {
            let device = facade.device
            guard let blocksBuffer = device.makeBuffer(bytes: bc1BlackBlock, length: 8,
                                                       options: .storageModeShared),
                  let outputBuffer = device.makeBuffer(length: 128,
                                                       options: .storageModeShared),
                  let queue = try? facade.makeCommandQueue() else {
                return ServiceProbeResult(name: "Argument replay", passed: false,
                                          detail: "Resource creation failed.")
            }
            memset(outputBuffer.contents(), 0xEE, 128)
            var params = BCParamsLayout()
            params.widthPixels = 8
            params.heightPixels = 4
            guard let paramsBuffer = device.makeBuffer(bytes: &params,
                                                       length: MemoryLayout<BCParamsLayout>.size,
                                                       options: .storageModeShared),
                  let library = (try? device.makeDefaultLibrary(bundle: Bundle(for: BCDecoder.self)))
                      ?? (try? device.makeDefaultLibrary(bundle: Bundle.main)),
                  let function = library.makeFunction(name: "mb_bc1_decode") else {
                return ServiceProbeResult(name: "Argument replay", passed: false,
                                          detail: "Kernel bindings unavailable.")
            }
            let pipeline = try device.makeComputePipelineState(function: function)

            let replay = ArgumentReplayEncoder()
            replay.encodeSetBuffer(blocksBuffer, offset: 0, index: 0)
            replay.encodeSetBuffer(outputBuffer, offset: 0, index: 1)
            replay.encodeSetBuffer(paramsBuffer, offset: 0, index: 2)
            let recorded = replay.count == 3

            guard let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return ServiceProbeResult(name: "Argument replay", passed: false,
                                          detail: "Encoding failed.")
            }
            encoder.setComputePipelineState(pipeline)
            replay.replay(into: encoder)
            encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                return ServiceProbeResult(name: "Argument replay", passed: false,
                                          detail: "Command buffer failed: \(error.localizedDescription)")
            }
            // One block at pitch 8 writes texels {0-3, 8-11, 16-19, 24-27}; the
            // rest stays at the 0xEE marker, proving the recorded params reached
            // the kernel through the replay.
            let written: Set<Int> = [0, 1, 2, 3, 8, 9, 10, 11, 16, 17, 18, 19, 24, 25, 26, 27]
            let out = outputBuffer.contents().bindMemory(to: UInt8.self, capacity: 128)
            var mismatches = 0
            for texel in 0..<32 {
                if written.contains(texel) {
                    if out[texel * 4 + 3] != 255 { mismatches += 1 }
                } else if out[texel * 4] != 0xEE {
                    mismatches += 1
                }
            }
            if recorded, mismatches == 0 {
                return ServiceProbeResult(name: "Argument replay", passed: true,
                                          detail: "3 recorded bindings replayed into a compute encoder.")
            }
            return ServiceProbeResult(name: "Argument replay", passed: false,
                                      detail: "recorded=\(recorded) mismatches=\(mismatches).")
        } catch {
            return ServiceProbeResult(name: "Argument replay", passed: false,
                                      detail: "\(error.localizedDescription)")
        }
    }
}
