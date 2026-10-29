# Coverage Report

This report describes what MetalBridge implements, what it converts, what is only partially equivalent, and what cannot be provided on iOS. The runtime source of truth is `Sources/MetalBridgeKit/Inventory/CompatibilityManifest.swift`.

## Summary

| Status | Count | Meaning |
| --- | ---: | --- |
| Native | 8 | Public API exists on iOS and is called directly. |
| Converted | 15 | The macOS behavior is mapped to a documented iOS equivalent. |
| Partial | 8 | Only part of the macOS behavior is reproduced. |
| Unsupported | 11 | No valid public iOS implementation exists. |
| **Total** | **42** | Compatibility records. |

The 8 native records are common APIs used by the bridge. 29 records are macOS-only API families, and 5 are the emulation services below.

## Native implementations

- `MTLCreateSystemDefaultDevice`
- `MTLDevice.makeBuffer(length:options:)`
- `MTLDevice.makeTexture(descriptor:)`
- `MTLCommandQueue`
- `MTLBlitCommandEncoder`
- `MTLRenderCommandEncoder`
- `MTLDevice.supportsFamily(_:)` on iOS 13+
- `MTLDevice.supportsFeatureSet(_:)` on iOS 12

These calls use public iOS Metal directly. No compatibility shim is placed in front of them.

## Converted implementations

| Record | Implementation | Important difference |
| --- | --- | --- |
| `mtl-device-removable` | `isRemovable` returns `false`. | iOS devices have no removable GPU. |
| `mtl-device-location` | `location` returns `.builtIn`. | No slot or external location. |
| `mtl-device-location-number` | `locationNumber` returns `0`. | One built-in location. |
| `mtl-device-depth24-stencil` | The capability query returns `false`. | The depth24 stencil8 format is absent from the iOS SDK. |
| `mtl-device-peer-group` | `peerGroupID` returns `0`. | The single GPU is modeled as one peer group. |
| `mtl-device-peer-index` | `peerIndex` returns `0`. | Single peer. |
| `mtl-device-peer-count` | `peerCount` returns `1`. | No multi-GPU peer group. |
| `mtl-storage-managed` | `BridgeStorageMode.managed` maps to `MTLStorageMode.shared`. | iOS has no managed storage; shared storage is CPU/GPU coherent. |
| `mtl-buffer-did-modify-range` | Validates the range and returns `.noActionRequired` for shared buffers. | Private and memoryless buffers throw. |
| `mtl-blit-synchronize-resource` | Returns `.noActionRequired` for shared resources. | Private and memoryless resources throw. |
| `mtl-blit-synchronize-texture` | Validates slice and mip level, then applies the shared-resource rule. | Private and memoryless textures throw. |
| `mtl-pixelformat-depth24-stencil` | Maps `depth24Unorm_stencil8` to `depth32Float_stencil8`. | Depth precision and memory footprint differ. |

The synchronization records are conversions, not stubs that pretend to perform a copy. They return a result that explicitly states that no operation is required on iOS shared storage. If the caller supplies private or memoryless storage, the bridge throws instead of claiming success.

## Partial implementations

| Record | What works | What is missing |
| --- | --- | --- |
| `mtl-all-devices` | Returns the one system device. | No multi-GPU enumeration and no hot-plug observer. |
| `mtl-device-low-power` | Reports the integrated-only iOS platform model. | The value is not a native query. |
| `mtl-device-headless` | Reports a display-capable system device. | iOS has no macOS-style headless GPU selection. |
| `mtl-device-max-transfer-rate` | Returns `0` meaning unknown. | No PCIe transfer rate is exposed. |
| `mtl-barrier-render-targets` | Uses a texture-scope memory barrier on iOS 16+. | Not the same render-target scope; iOS 12-15 throw unsupported. |
| `mtl-texture-barrier` | Uses the same iOS 16+ barrier adapter. | Deprecated macOS API; no exact older-iOS equivalent. |

## Unsupported

| Record | Why it is unsupported on iOS |
| --- | --- |
| `mtl-device-observer-remove` | No device observer exists. |
| `mtl-device-notifications` | iOS has one built-in GPU and no public hot-plug event stream. |
| `mtl-device-concurrent-compilation` | No iOS compile-scheduling control. |
| `mtl-pixelformat-x24-stencil` | No public X24 stencil-only pixel format. |
| `mtl-buffer-remote-storage` | No peer-GPU buffer alias. |
| `mtl-buffer-remote-view` | No cross-device address-space alias. |
| `mtl-texture-remote-storage` | No peer-GPU texture alias. |
| `mtl-texture-remote-view` | No cross-device texture view. |
| `mtl-feature-set-macos` | macOS feature-set values are not iOS capability identifiers. |
| `mtl-heap-sparse` | The sparse heap type is not exposed to iOS apps. |
| `mtl-command-buffer-device-removed` | iOS has no public device-removal error path. |

Unsupported operations throw `BridgeError.unsupported` or return a `BridgeResult.unsupported` value. They are never silently converted into a successful no-op. The three manifest-only families (macOS feature sets, sparse heaps, and device-removal errors) are also exposed through `PlatformLimitationAdapter.isSupported(_:)`, which returns an explicit unsupported result.

## Emulation services

Beyond the macOS-only API records above, the bridge emulates five runtime capabilities that have no native A9 path, each verified against a reference (see [docs/COMPAT_SHADER.md](docs/COMPAT_SHADER.md) for the shader-side contract):

| Service | Emulates | Manifest record | Verification |
| --- | --- | --- | --- |
| `BCDecoder` | BC1-BC5, BC6H, BC7 texture creation from compressed payloads, decode-to-RGBA via compute | `mtl-emulation-bc-decode` (converted) | Texel-for-texel differential against vendored bcdec v0.985; all tests pass. |
| `TessellationEmulator` | The tessellation stage via a compute pre-pass and draw-call generation | `mtl-emulation-tessellation` (partial) | Harness passes; tess-factor clamping matches the family limit. |
| `FenceBridge` | MTLSharedEvent-style fences with signal/notify/wait | `mtl-emulation-fences` (converted) | Host driver and unit tests pass. |
| `SparseFallback` | Sparse texture mapping as a dense zeroed backing with page tracking and a mapping-changed event | `mtl-emulation-sparse` (partial) | Host driver and unit tests pass; memory equals a fully-resident texture (documented limitation). |
| `ArgumentReplayEncoder` | Argument-buffer-style recorded bindings replayed into ordinary encoders | `mtl-emulation-argument-replay` (converted) | Recorded bindings reach a live compute encoder in the host driver and tests. |

`ServiceProbes` bundles one probe per service and is surfaced in the Lab's Service Probes section. The manifest carries these five as the `Emulation services` group (`mtl-emulation-*`), bringing it to 42 records.

Shaders written against Metal 2/3/4 are brought into the A9-safe MSL 1.2 subset by `Tools/metal_retarget.py` (grid-attribute rewrites to reserved buffer slots 29-31, namespace mapping) with unsupported constructs reported explicitly.

## A9 baseline policy

The minimum hardware target is Apple A9. A9 is in Apple GPU family 3.

On iOS 13 and newer, `BridgeCapabilities` checks `supportsFamily(.apple3)` through `.apple10`. On iOS 12, it checks the legacy feature sets up to `iOS_GPUFamily3_v4` and above. The bridge does not use the device name to infer the GPU.

The bridge does not assume Metal 3, Metal 4, MetalFX, argument-buffer tiers, sparse heaps, or peer-GPU features. Those capabilities are either queried at runtime or reported as unsupported. The shader uses Metal Shading Language 1.2, and the build enforces that version with `-std=ios-metal1.2` plus a compile-time assertion.

## Behavior differences that callers must handle

- Managed storage code that relies on explicit `didModifyRange` or blit synchronization must accept that iOS shared storage is already coherent.
- Code that requires a removable or externally located GPU must branch on the unsupported/partial result.
- Code that uses render-target barriers must handle the iOS 12-15 unsupported path.
- Code that uses depth24 stencil8 must accept the depth32Float stencil8 conversion and its precision/memory difference.
- Code that enumerates multiple devices or observes device arrival/removal must not assume that behavior exists on iOS.
- Code that shares resources between GPUs must not assume peer aliases exist on iOS.

## Excluded from scope

The inventory does not use private, SPI, or undocumented APIs. It does not claim that AppKit, macOS window-server integration, or macOS-only MetalKit view integration can be ported to iOS. Those are outside the public Metal API and require platform-specific UI code.
