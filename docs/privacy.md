# MetalBridge — Privacy Policy

MetalBridge is a from-scratch Swift iOS compatibility layer for public Metal APIs declared on macOS but not available on native iOS Metal. It targets Apple A9 and newer.

## Data we collect

**None.** MetalBridge is a compatibility framework. It does not collect, store, or transmit any personal data. No analytics, no telemetry, no advertising, no user profiling.

## Local-only operation

MetalBridge runs entirely on the host device:

- Adapts macOS Metal APIs to public iOS Metal equivalents locally
- Emulates macOS features with no iOS path (BC decode, tessellation, fences, sparse textures, argument replay) locally
- Reports unsupported APIs explicitly via `BridgeError.unsupported`

No data leaves the device unless your application explicitly sends it.

## Logs

Diagnostic output may be produced during verification and testing. It is local only and never uploaded by the framework.

## Children

MetalBridge collects no data from anyone, including children.

## Your rights

Because no data is collected, there is nothing to access, export or delete on our side.

## Contact

Open an issue on the [MetalBridge GitHub repository](https://github.com/Witch-Launcher/MetalMacOSPortiOS).
