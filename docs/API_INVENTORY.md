# Metal API Inventory

This is the Phase 1 inventory for MetalBridge. It compares the public Metal API surface in the macOS 26.2 SDK with the iOS 26.2 SDK using Xcode 26.3.

## Method

`Tools/metal_api_inventory.py` scans every public header in `Metal.framework/Headers` for both SDKs. It records:

- Declarations with macOS availability and explicit `API_UNAVAILABLE(ios)`.
- Declarations with macOS availability but no iOS availability annotation.
- The reverse-direction declarations.

The raw scan is saved in `docs/generated/metal_api_inventory.json` and `.csv`. The scan is line-oriented and includes enum constants and multiple symbols on one line, so its count is not a count of unique APIs. The curated tables below consolidate the scan into API families.

The verified scan found 43 macOS-only declaration lines and 27 reverse-direction declaration lines across 96 headers per SDK. The reverse set is mostly iOS-only, but it also includes tvOS-only values and annotations that are unavailable on both platforms.

Apple's public Metal documentation is at <https://developer.apple.com/documentation/metal>. Each group below names the SDK header that declares the APIs, so a declaration can be checked against both the macOS and iOS SDKs. Deep documentation links are deliberately not guessed; use the symbol name and header with Apple's documentation search.

## What "macOS ARM-only" means here

The SDK does not expose a static list called "macOS ARM-only". Availability annotations can identify a macOS-only declaration, but they do not distinguish Intel Macs from Apple Silicon. Apple Silicon capability is queried at runtime through GPU families such as `Mac2`.

The bridge therefore does the following:

- Treats a declaration as macOS-only only when the iOS SDK does not expose it.
- Detects Apple GPU families on iOS at runtime instead of inferring a chip or Mac family.
- Never reports the macOS `Mac2` family on an iOS device.
- Never turns an Apple Silicon-only hardware feature into a fake iOS capability.

Private and undocumented APIs are outside this inventory.

## Reverse scan: iOS-only and unavailable-on-both declarations

The scanner also recorded 27 reverse-direction lines from the iOS headers. They explain why the raw comparison is asymmetric:

| Category | Lines | Relevance |
| --- | ---: | --- |
| iOS GPU feature sets | 17 | The bridge uses the `iOS_GPUFamily3_v4` through `5_v1` probes only on iOS 12; macOS has its own feature-set values. |
| tvOS GPU feature sets | 7 | Not iOS APIs. |
| Deprecated MSL 1.0 | 1 | The bridge shader uses MSL 1.2. |
| `init` methods unavailable on both platforms | 2 | Not usable APIs. |

The complete line list is in `docs/generated/metal_api_inventory.csv`. These declarations are not separate macOS-to-iOS coverage records; the iOS GPU feature-set path is folded into the native `BridgeCapabilities` probe for iOS 12.

## Common APIs used natively

These public APIs exist on both platforms and are called directly by the bridge.

| API | macOS | iOS | Status | Use |
| --- | --- | --- | --- | --- |
| `MTLCreateSystemDefaultDevice` | 10.11+ | 8.0+ | Native | Resolve the system GPU. |
| `MTLDevice.makeBuffer(length:options:)` | 10.11+ | 8.0+ | Native | Buffer allocation after storage adaptation. |
| `MTLDevice.makeTexture(descriptor:)` | 10.11+ | 8.0+ | Native | Texture allocation after storage/format adaptation. |
| `MTLCommandQueue` | 10.11+ | 8.0+ | Native | Command submission. |
| `MTLBlitCommandEncoder` | 10.11+ | 8.0+ | Native | Encoder accepted by the synchronization adapter. |
| `MTLRenderCommandEncoder` | 10.11+ | 8.0+ | Native | Encoder accepted by the barrier adapter and render probe. |
| `MTLDevice.supportsFamily(_:)` | 10.15+ | 13.0+ | Native | Apple GPU family probe on modern iOS. |
| `MTLDevice.supportsFeatureSet(_:)` | 10.11+ | 8.0-16.0 | Native | Legacy probe used only on iOS 12. |

## macOS-only APIs and decisions

### Device topology and notifications

Source headers: `MTLDevice.h`

| API | macOS | iOS | Status | Bridge behavior | Difference / limitation |
| --- | --- | --- | --- | --- | --- |
| `MTLCopyAllDevicesWithObserver(observer:handler:)` | 10.13+ | Unavailable | Partial | `topology.allDevices()` returns the one system device. | No multi-GPU enumeration and no hot-plug observer. |
| `MTLRemoveDeviceObserver(_:)` | 10.13+ | Unavailable | Unsupported | Throws `BridgeError.unsupported`. | No observer can be installed on iOS. |
| `MTLDeviceWasAddedNotification` / `RemovalRequested` / `WasRemoved` and handler types | 10.13+ | Unavailable | Unsupported | No callback is synthesized. | iOS has one built-in GPU and no public hot-plug stream. |

### Device properties

Source header: `MTLDevice.h`

| API | macOS | iOS | Status | Bridge behavior | Difference / limitation |
| --- | --- | --- | --- | --- | --- |
| `MTLDevice.isLowPower` | 10.11+ | Unavailable | Partial | Returns `true` as an integrated-GPU inference. | Not obtained from the macOS property. |
| `MTLDevice.isHeadless` | 10.11+ | Unavailable | Partial | Returns `false`. | iOS has no macOS-style headless device selection. |
| `MTLDevice.isRemovable` | 10.13+ | Unavailable | Converted | Returns `false`. | iOS hardware has no removable GPU. |
| `MTLDevice.location` | 10.15+ | Unavailable | Converted | Returns `.builtIn`. | No slot or external location. |
| `MTLDevice.locationNumber` | 10.15+ | Unavailable | Converted | Returns `0`. | Single built-in location. |
| `MTLDevice.maxTransferRate` | 10.15+ | Unavailable | Partial | Returns `0` meaning unknown. | No PCIe transfer rate is exposed. |
| `MTLDevice.isDepth24Stencil8PixelFormatSupported` | 10.11+ | Unavailable | Converted | Returns `false`. | The format is unavailable in the iOS SDK. |
| `MTLDevice.peerGroupID` | 10.15+ | Unavailable | Converted | Returns `0`. | One peer group is modeled. |
| `MTLDevice.peerIndex` | 10.15+ | Unavailable | Converted | Returns `0`. | Single GPU peer. |
| `MTLDevice.peerCount` | 10.15+ | Unavailable | Converted | Returns `1`. | No multi-GPU peer group. |
| `MTLDevice.shouldMaximizeConcurrentCompilation` | 13.3+ | Unavailable | Unsupported | Query is unsupported; setter throws. | No iOS compile-scheduling control. |

### Storage and buffer updates

Source headers: `MTLResource.h`, `MTLBuffer.h`

| API | macOS | iOS | Status | Bridge behavior | Difference / limitation |
| --- | --- | --- | --- | --- | --- |
| `MTLStorageMode.managed` / `MTLResourceStorageModeManaged` | 10.11+ | Unavailable | Converted | Mapped to `MTLStorageMode.shared`. | Managed storage uses explicit CPU/GPU synchronization on macOS; shared storage is coherent on iOS. |
| `MTLBuffer.didModifyRange(_:)` | 10.11+ | Unavailable | Converted | Validates the range; returns no-action-required for shared buffers. | Private and memoryless buffers throw. The bridge does not fabricate an upload. |

### Blit synchronization

Source header: `MTLBlitCommandEncoder.h`

| API | macOS | iOS | Status | Bridge behavior | Difference / limitation |
| --- | --- | --- | --- | --- | --- |
| `MTLBlitCommandEncoder.synchronizeResource(_:)` | 10.11+ | Unavailable | Converted | Validates storage; returns no-action-required for shared resources. | Private and memoryless resources throw. |
| `MTLBlitCommandEncoder.synchronizeTexture(_:slice:level:)` | 10.11+ | Unavailable | Converted | Validates slice and mip level, then applies the shared-resource rule. | Private and memoryless textures throw. |

### Barriers

Source headers: `MTLCommandEncoder.h`, `MTLRenderCommandEncoder.h`

| API | macOS | iOS | Status | Bridge behavior | Difference / limitation |
| --- | --- | --- | --- | --- | --- |
| `MTLBarrierScope.renderTargets` | 10.14+ | Unavailable | Partial | On iOS 16+, emits `memoryBarrier(scope: .textures, after: .fragment, before: .fragment)`. | Not an exact render-target scope; iOS 12-15 throw unsupported. |
| `MTLRenderCommandEncoder.textureBarrier()` | 10.11-10.14 (deprecated) | Unavailable | Partial | Uses the same texture-scope barrier adapter. | Deprecated macOS API; no exact iOS equivalent on older versions. |

### Pixel formats

Source header: `MTLPixelFormat.h`

| API | macOS | iOS | Status | Bridge behavior | Difference / limitation |
| --- | --- | --- | --- | --- | --- |
| `MTLPixelFormat.depth24Unorm_stencil8` | 10.11+ | Unavailable | Converted | Mapped to `MTLPixelFormat.depth32Float_stencil8`. | Higher depth precision and a different memory footprint. |
| `MTLPixelFormat.x24_stencil8` | 10.12+ | Unavailable | Unsupported | Throws or returns an unsupported result. | No public iOS X24 stencil-only format. |

### Peer-GPU resources

Source headers: `MTLBuffer.h`, `MTLTexture.h`

| API | macOS | iOS | Status | Bridge behavior | Difference / limitation |
| --- | --- | --- | --- | --- | --- |
| `MTLBuffer.remoteStorageBuffer` | 10.15+ | Unavailable | Unsupported | Throws `BridgeError.unsupported`. | No peer-GPU buffer alias on iOS. |
| `MTLBuffer.newRemoteBufferViewForDevice(_:)` | 10.15+ | Unavailable | Unsupported | Throws `BridgeError.unsupported`. | No cross-device address-space alias. |
| `MTLTexture.remoteStorageTexture` | 10.15+ | Unavailable | Unsupported | Throws `BridgeError.unsupported`. | No peer-GPU texture alias. |
| `MTLTexture.newRemoteTextureViewForDevice(_:)` | 10.15+ | Unavailable | Unsupported | Throws `BridgeError.unsupported`. | No cross-device texture view. |

### Feature sets, heaps, and command errors

Source headers: `MTLDevice.h`, `MTLHeap.h`, `MTLCommandBuffer.h`

| API | macOS | iOS | Status | Bridge behavior | Difference / limitation |
| --- | --- | --- | --- | --- | --- |
| `MTLFeatureSet` macOS GPU families | 10.11+ | Unavailable | Unsupported | Reported as not applicable. | macOS feature-set values are not iOS capability identifiers. |
| `MTLHeapType.sparse` | 11.0+ | Unavailable | Unsupported | Reported as unavailable. | The sparse heap type is not exposed to iOS apps. |
| `MTLCommandBufferError.deviceRemoved` | 10.13+ | Unavailable | Unsupported | Reported as not applicable. | iOS has no public device-removal error path. |

## Inventory result

| Result | Count |
| --- | ---: |
| Native common APIs | 8 |
| Converted macOS-only APIs | 12 |
| Partial macOS-only APIs | 6 |
| Unsupported macOS-only APIs | 11 |
| Total compatibility records | 37 |

The exact source of truth for runtime use is `Sources/MetalBridgeKit/Inventory/CompatibilityManifest.swift`. The tests assert the totals and uniqueness of the records. macOS feature sets, sparse heaps, and device-removal errors also have a direct status query through `PlatformLimitationAdapter.isSupported(_:)`.

The manifest also carries an `Emulation services` group of 5 records (`mtl-emulation-*`) for the runtime capabilities the bridge emulates rather than maps: BC decode, tessellation, fences, sparse mapping, and argument-replay bindings. Those bring the manifest to 42 records (8 native, 15 converted, 8 partial, 11 unsupported); they are runtime emulations, not macOS-only API families, and are documented in [docs/COMPAT_SHADER.md](COMPAT_SHADER.md).
