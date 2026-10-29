# MetalBridge

MetalBridge is a from-scratch Swift iOS compatibility layer for public Metal APIs that are declared on macOS but have no native iOS Metal API. It includes a framework, an inspector/lab app, tests, an SDK inventory generator, and a coverage report.

This project does not claim that every macOS Metal API can exist on iOS. It implements real adapters where an iOS equivalent exists, marks partial behavior as partial, and throws a clear unsupported error where no valid public iOS implementation exists.

## Project layout

```text
Sources/MetalBridgeKit/Core/        Public bridge types and capability probe
Sources/MetalBridgeKit/Adapters/    Storage, format, synchronization, barrier, topology adapters
Sources/MetalBridgeKit/Emulation/   BC decode, tessellation, fences, sparse, argument buffers
Sources/MetalBridgeKit/Inventory/   Coverage manifest used by the app and tests
Sources/MetalBridgeLab/             UIKit inspector, render probe, and service probes
Shaders/                            MSL 1.2 validation shader
Tests/MetalBridgeKitTests/          Logic and Metal smoke tests
Tools/metal_api_inventory.py        macOS/iOS SDK declaration scanner
Tools/metal_retarget.py             Shader retarget scanner and rewriter for the A9 subset
Tools/run_bc_differential.sh        BC decode differential harness (GPU vs bcdec)
Tools/FacadeDriver/                 macOS facade driver (build_and_run.sh)
docs/API_INVENTORY.md               Phase 1 API inventory and decisions
docs/COVERAGE.md                    Phase 2 coverage report
docs/COMPAT_SHADER.md               Shader compatibility contract and retarget rules
docs/VERIFICATION.md                Build and verification record
```

## Phase 1: API inventory

The inventory compares the public Metal headers in the macOS 26.2 SDK and the iOS 26.2 SDK with Xcode 26.3. The scanner records declarations that are macOS-available but not iOS-available, and the reverse. It found 43 macOS-only declaration lines and 27 reverse-direction declaration lines across 96 headers per SDK; the reverse set is mostly iOS-only, with some tvOS-only and unavailable-on-both annotations.

Those raw lines include properties, methods, constants, and enum cases. The curated inventory in [docs/API_INVENTORY.md](docs/API_INVENTORY.md) groups them into 29 macOS-only API families plus 8 common native APIs used by the bridge.

`macOS ARM-only` is not a fixed SDK list. SDK availability identifies macOS-only declarations; Apple Silicon-specific capability is a runtime GPU-family property. The bridge detects iOS Apple GPU families at runtime and never reports the macOS `Mac2` family on iOS.

## Phase 2: compatibility layer

The implemented native path uses public iOS Metal APIs directly. The adapters cover:

- Managed storage mapped to shared storage.
- `didModifyRange` and blit synchronization made no-ops only where iOS shared storage is already coherent.
- Depth24 stencil8 format mapped to depth32Float stencil8.
- Render-target barriers mapped to a texture-scope barrier on iOS 16+, with an explicit older-iOS limitation.
- Single-device topology values for a one-GPU platform.
- Explicit unsupported errors for device hot-plug, peer-GPU resource sharing, sparse heaps, macOS feature sets, and device-removal errors.

The coverage manifest contains 37 records: 8 native common APIs, 12 converted APIs, 6 partial APIs, and 11 unsupported APIs. `PlatformLimitationAdapter` exposes macOS feature sets, sparse heaps, and device-removal errors as explicit unsupported results for callers that need a direct query.

## Shader retargeting

Shaders written against Metal 2/3/4-era MSL are brought into the A9-safe MSL 1.2 subset by `Tools/metal_retarget.py`: it reports unsupported constructs (ray tracing, mesh shaders, 64-bit atomics, function constants, argument-buffer structs) and mechanically rewrites the validated cases, chiefly the `[[threads_per_grid]]` family into reserved buffer slots (29-31) because that attribute returns the padded dispatch grid under this toolchain. The full contract is in [docs/COMPAT_SHADER.md](docs/COMPAT_SHADER.md).

```sh
python3 Tools/metal_retarget.py Sources/MyGame/Shaders --strict
```

The bridge's own shader subset is enforced the same way: the shipped shaders report zero findings under `--strict`.

## Build

Requirements:

- Xcode 26.3 / iOS SDK 26.2.
- XcodeGen 2.46 or newer.
- iOS deployment target 12.0.
- arm64 device with Metal support, A9 or newer.

Generate the project:

```sh
xcodegen generate
```

Build Debug:

```sh
xcodebuild -project MetalBridge.xcodeproj \
  -target MetalBridgeLab \
  -configuration Debug \
  -sdk iphoneos \
  -arch arm64 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Build Release:

```sh
xcodebuild -project MetalBridge.xcodeproj \
  -target MetalBridgeLab \
  -configuration Release \
  -sdk iphoneos \
  -arch arm64 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Build the test bundle:

```sh
xcodebuild -project MetalBridge.xcodeproj \
  -target MetalBridgeKitTests \
  -configuration Debug \
  -sdk iphoneos \
  -arch arm64 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The app target remains iOS 12.0. The test target uses iOS 13.0 because the XCTest framework bundled with this toolchain requires it.

The host code is Swift. The only non-Swift source is the required Metal Shading Language shader. No C, C++, or Objective-C++ bridge is used.

The shader build uses `MTL_COMPILER_FLAGS=-std=ios-metal1.2`, and `Shaders/Probe.metal` contains a compile-time assertion that rejects a newer MSL version.

## Run

Open `MetalBridge.xcodeproj`, select the shared `MetalBridgeLab` scheme (not the `MetalBridgeKit` framework scheme), select a development team, and run it on an A9 or newer device running iOS 12.0 or newer. If Xcode asks for a run destination, choose the physical device rather than a simulator. The app displays:

- The runtime device and GPU-family probe.
- A render probe that compiles the bundled metallib and renders one offscreen triangle.
- Every compatibility record with its status, implementation, and limitation.

The triangle is only a pipeline validation example. Tap **Run Probe** to execute it; the probe is not run automatically at launch. The framework and coverage manifest are the delivered compatibility layer.

## Regenerate the inventory

```sh
python3 Tools/metal_api_inventory.py
```

This writes `docs/generated/metal_api_inventory.json` and `.csv`. The official inventory decisions are in `docs/API_INVENTORY.md`, not in the raw scan.

## Verification status

Verified on 2026-10-22 with Xcode 26.3 (17C529) and iOS SDK 26.2:

- Debug and Release app builds succeeded for `arm64-apple-ios12.0`.
- The test target compiled successfully.
- The app bundle contains `default.metallib` with `probe_vertex` and `probe_fragment`.
- The shader compile command includes `-std=ios-metal1.2`.
- The executable and embedded framework are arm64.
- `Info.plist` reports `MinimumOSVersion=12.0`, bundle ID `dev.metalbridge.lab`, `UILaunchScreen`, and `UIRequiresFullScreen`.

Not verified:

- No runtime launch, render probe result, gesture, performance, or thermal result.
- No A9 hardware run. No iOS Simulator runtime is installed on the verification host.
- No signed device installation.
- The test bundle was compiled, not executed.

See [docs/VERIFICATION.md](docs/VERIFICATION.md) for the command log summary.

## Limitations

- The compatibility layer is not a complete replacement for the macOS Metal runtime.
- APIs with no public iOS equivalent remain unsupported and are never reported as successful.
- Multi-GPU topology, device hot-plug, peer-GPU resource aliasing, managed storage, and macOS feature sets cannot be reproduced faithfully on iOS.
- The app has no asset catalog or custom icon.
- The render probe uses a blocking `waitUntilCompleted` only as a one-shot validation and is not the renderer's frame loop.

## Independence

This is a new implementation with its own product name, bundle identifiers, source layout, inventory, and documentation. It does not reuse source, resources, configuration, or naming from any earlier renderer project.
