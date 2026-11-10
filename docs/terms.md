# MetalBridge — Terms of Service

By using MetalBridge you agree to these terms.

## What we provide

MetalBridge is a Swift iOS compatibility layer that adapts macOS-only Metal APIs to public iOS Metal equivalents, and emulates macOS features with no native iOS path. It is designed for Apple A9 and newer.

## What we do not provide

- No GPU hardware — you supply the device
- No game files or content
- No uptime or support guarantees
- No affiliation with Apple, Khronos or Mojang
- No LICENSE file (see repository for licensing information)

## Your responsibilities

- Comply with Apple's App Store rules if distributing on Apple platforms
- Understand that unsupported APIs throw `BridgeError.unsupported` — they never silently succeed
- Use MetalBridge for lawful purposes only

## Third-party components

MetalBridge references Apple Metal frameworks and vendored `bcdec` BC texture decoder. Their own terms apply.

## No warranty

Provided "as is" without warranty of any kind.

## Contact

Open an issue on the [MetalBridge GitHub repository](https://github.com/Witch-Launcher/MetalMacOSPortiOS).
