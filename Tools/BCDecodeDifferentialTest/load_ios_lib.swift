import Foundation
import Metal

// Try loading the iOS-compiled framework metallib on the host.
let path = "/Volumes/D/MetalBridgeA9/build/Debug-iphoneos/MetalBridgeKit.framework/default.metallib"
let url = URL(fileURLWithPath: path)
guard let device = MTLCreateSystemDefaultDevice() else { print("no device"); exit(1) }
do {
    let lib = try device.makeLibrary(URL: url)
    print("LOADED via URL; functionNames:", lib.functionNames.filter { $0.contains("bc") || $0.contains("tess") })
} catch {
    print("URL load failed: \(error)")
}
