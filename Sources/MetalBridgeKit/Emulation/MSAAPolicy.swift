import Foundation

/// MSAA policy for macOS content on Apple GPUs.
///
/// macOS GPU family 1 lists up to 8x MSAA; Apple GPUs (including A9, Apple family 3)
/// support 1x, 2x, and 4x. Requesting 8x on iOS is not an error on macOS builds, so
/// the bridge downlevels to the largest supported count instead of failing, and every
/// caller can see the decision through the returned note.
public enum MSAAService {
    public struct Resolution {
        public let count: Int
        public let note: String
    }

    public static func resolve(sampleCount: Int, supported: [Int]) -> Resolution {
        if supported.contains(sampleCount) {
            return Resolution(count: sampleCount,
                              note: "Sample count \(sampleCount) is native on this device.")
        }
        let fallback = supported.filter { $0 < sampleCount }.max() ?? 1
        if fallback == 1, sampleCount > 1 {
            return Resolution(count: 1,
                              note: """
                              Requested sample count \(sampleCount) is unsupported; downleveled to 1x. \
                              Supported counts: \(supported.map(String.init).joined(separator: ", ")).
                              """)
        }
        return Resolution(count: fallback,
                          note: """
                          Requested sample count \(sampleCount) is unsupported on Apple GPUs \
                          (max 4x per the Metal Feature Set Tables); downleveled to \(fallback)x. \
                          macOS GPU family 1 supports up to 8x MSAA, so edge quality can differ.
                          """)
    }
}
