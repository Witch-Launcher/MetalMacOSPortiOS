import Foundation
import Metal
import MetalBridgeKit

struct ProbeReport {
    let passed: Bool
    let detail: String
}

enum RenderProbe {
    static func run(bridge: MetalBridge) -> ProbeReport {
        do {
            let library: MTLLibrary
            do {
                library = try bridge.device.makeDefaultLibrary(bundle: Bundle.main)
            } catch {
                return ProbeReport(passed: false, detail: "default.metallib could not be loaded: \(error.localizedDescription)")
            }
            guard let vertex = library.makeFunction(name: "probe_vertex") else {
                return ProbeReport(passed: false, detail: "probe_vertex is missing from default.metallib.")
            }
            guard let fragment = library.makeFunction(name: "probe_fragment") else {
                return ProbeReport(passed: false, detail: "probe_fragment is missing from default.metallib.")
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            let pipeline = try bridge.device.makeRenderPipelineState(descriptor: descriptor)
            let texture = try bridge.makeTexture(width: 64,
                                                 height: 64,
                                                 pixelFormat: .bgra8Unorm,
                                                 usage: [.renderTarget, .shaderRead],
                                                 mode: .shared)
            let queue = try bridge.makeCommandQueue()
            guard let commandBuffer = queue.makeCommandBuffer() else {
                return ProbeReport(passed: false, detail: "Command-buffer creation returned nil.")
            }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                return ProbeReport(passed: false, detail: "Render-encoder creation returned nil.")
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            if let error = commandBuffer.error {
                return ProbeReport(passed: false, detail: "Command buffer failed: \(error.localizedDescription)")
            }

            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                texture.getBytes(base,
                                 bytesPerRow: 4,
                                 from: MTLRegionMake2D(32, 32, 1, 1),
                                 mipmapLevel: 0)
            }

            let passed = pixel[2] > 200 && pixel[0] < 50
            return ProbeReport(passed: passed,
                               detail: "Center pixel BGRA = [\(pixel[0]), \(pixel[1]), \(pixel[2]), \(pixel[3])].")
        } catch {
            return ProbeReport(passed: false, detail: "Probe error: \(error.localizedDescription)")
        }
    }
}
