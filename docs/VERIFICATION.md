# Verification Record

## Environment

- Date: 2026-10-22 (extended 2026-10-28)
- Xcode: 26.3 (17C529)
- iOS SDK: 26.2
- macOS SDK used for inventory: 26.2
- Deployment target: iOS 12.0 (app), iOS 13.0 (test bundle)
- Architecture: arm64
- XcodeGen: 2.46.0

## Inventory generation

```sh
python3 Tools/metal_api_inventory.py
```

Result:

- macOS Metal headers scanned: 96
- iOS Metal headers scanned: 96
- macOS-only declaration lines: 43
- Reverse-direction declaration lines: 27
- Output: `docs/generated/metal_api_inventory.json`
- Output: `docs/generated/metal_api_inventory.csv`

## Manifest validation

The manifest was compiled and executed as a small macOS Swift check:

```text
records 37
native 8
converted 12
partial 6
unsupported 11
groups 11
unique 37
```

The same totals are asserted by `Tests/MetalBridgeKitTests/BridgeLogicTests.swift`. The test sources also cover storage conversion, pixel-format conversion, explicit platform limitations, remote-resource failures, and Metal smoke paths for buffers, textures, and device location.

## Builds

Debug app build:

```sh
xcodebuild -project MetalBridge.xcodeproj \
  -target MetalBridgeLab \
  -configuration Debug \
  -sdk iphoneos \
  -arch arm64 \
  CODE_SIGNING_ALLOWED=NO \
  clean build
```

Result: `BUILD SUCCEEDED`.

Release app build:

```sh
xcodebuild -project MetalBridge.xcodeproj \
  -target MetalBridgeLab \
  -configuration Release \
  -sdk iphoneos \
  -arch arm64 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Result: `BUILD SUCCEEDED`.

Test bundle build:

```sh
xcodebuild -project MetalBridge.xcodeproj \
  -target MetalBridgeKitTests \
  -configuration Debug \
  -sdk iphoneos \
  -arch arm64 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Result: `BUILD SUCCEEDED`.

The app and test builds also succeed with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` and `GCC_TREAT_WARNINGS_AS_ERRORS=YES`. The only build-log notice is the expected AppIntents metadata skip:

```text
Metadata extraction skipped. No AppIntents.framework dependency found.
```

No Swift compiler errors or warnings were emitted.

## Shader verification

The clean Debug build contains a Metal compile command with:

```text
metal -c -target air64-apple-ios12.0 ... -std=ios-metal1.2 ...
```

`Shaders/Probe.metal` also contains:

```metal
static_assert(__METAL_VERSION__ == 120, "MetalBridgeKit render probe requires Metal Shading Language 1.2");
```

The shader compiled in both Debug and Release.

## Bundle verification

`build/Release-iphoneos/MetalBridgeLab.app`:

- `MetalBridgeLab`: Mach-O 64-bit executable arm64.
- `Frameworks/MetalBridgeKit.framework/MetalBridgeKit`: Mach-O 64-bit dynamically linked shared library arm64.
- `default.metallib`: `MetalLib, version 1.2.3`.
- `default.metallib` contains `probe_vertex` and `probe_fragment`.
- `Info.plist`:
  - `CFBundleIdentifier = dev.metalbridge.lab`
  - `MinimumOSVersion = 12.0`
  - `UILaunchScreen` present
  - `UIRequiresFullScreen = 1`
  - `UIUserInterfaceStyle = Dark`
- The embedded `MetalBridgeKit.framework` contains its own `Info.plist` with `CFBundlePackageType=FMWK`, bundle ID `dev.metalbridge.kit`, and `MinimumOSVersion=12.0`.
- The app links `@rpath/MetalBridgeKit.framework/MetalBridgeKit` and carries `@executable_path/Frameworks` in its rpath.
- The test bundle contains `Info.plist` with `CFBundlePackageType=BNDL`, bundle ID `dev.metalbridge.kit.tests`, and `MinimumOSVersion=13.0`.

## Not verified

- No app launch or runtime UI inspection.
- No render probe execution on an iOS device or simulator.
- No A9 hardware run.
- No signed installation.
- No performance or thermal measurement.
- The test bundle was compiled but not executed.

Reason: the verification host has no installed iOS Simulator runtime and no available A9 device. The device builds and bundle inspection pass, but runtime claims are intentionally not made.

## 2026-10-28 extension: BC decode and emulation services

The verification host is an Intel Mac (x86_64) running macOS 15.7.7 with a KBL Intel GPU, so iOS runtime checks still cannot run here; the new runtime claims below are macOS-host claims made through the same Swift sources the iOS build uses. An Apple A11 device (Apple GPU family 4) is available to the project owner for a future on-device run; no device run has happened yet.

### BC decode

`Tools/run_bc_differential.sh` compiles `Sources/MetalBridgeKit/Shaders/BCDecode.metal` with `-std=macos-metal1.2` and runs `Tools/BCDecodeDifferentialTest` against the vendored bcdec v0.985 (`third_party/bcdec/bcdec.h`) on the CPU. Result:

```text
ALL BC DIFFERENTIAL TESTS PASSED
```

Covered: BC1, BC2, BC3, BC4 unorm/snorm, BC5 unorm/snorm, BC6H signed/unsigned across all modes, BC7 including seed sweeps, texel-for-texel against bcdec. A root-cause defect was found and fixed during this work: `bc_read_bits_at` read the already-consumed bit-stream words instead of the pristine block words, zeroing BC7 index streams; the fix stores `origLow`/`origHigh` in `BCBitStream`.

A second defect class was found on the host facade path: `[[threads_per_grid]]` returned the padded dispatch grid (rounded up to whole threadgroups), so padded threads wrote out of bounds. All seven BC kernels and both tessellation kernels now derive the logical grid from the params buffer instead; the differential harness re-passed after the change.

### Host facade driver

`Tools/FacadeDriver/build_and_run.sh` compiles the real framework Swift sources plus a metallib built from `Sources/MetalBridgeKit/Shaders/BCDecode.metal` and `Shaders/Probe.metal` (`-std=macos-metal1.2`) into a one-shot app bundle, then runs the facade end-to-end. Latest run:

```text
PASS 1  BC1 decode via facade, 16 texels black
PASS 1b BCDecoder.decodeMip into plain 4x4 (mip0/1/2 dump)
PASS 1c mip dump of decoded chain
PASS 2  BC7 mip chain (5 levels), texel 0 = 38,151,241,255
PASS 3  native path keeps managed->shared conversion
PASS 4  BC1 decoded then blitted into private storage
PASS 5  memoryless BC payload rejected as unsupported
PASS 6  32x32 BC1 full mip chain decoded; last mip alpha 255
PASS 7  FenceBridge signal/notify/wait
PASS 8  SparseFallback pages, zeros on dealloc, mapping event
PASS 9  ArgumentReplayEncoder replay reaches compute encoder
PASS 10 ServiceProbes.run() all services (5 probes)
ALL FACADE TESTS PASSED
```

`ServiceProbes` (the Lab's Service Probes section) passed all five: BC1 decode, BC7 decode, Fences, Sparse textures, Argument replay.

### iOS builds

`xcodegen generate` plus Debug builds of `MetalBridgeKit`, `MetalBridgeLab`, and `MetalBridgeKitTests` for `arm64-apple-ios` all report `BUILD SUCCEEDED` with the new sources: `Emulation/BCDecode/BCDecoder.swift`, `Emulation/Sparse/SparseFallback.swift`, `Emulation/Fences/FenceBridge.swift`, `Emulation/ArgumentBuffers/ArgumentReplayEncoder.swift`, `Emulation/ServiceProbes.swift`, and the corresponding tests. One environment incident during this session: xcodebuild lost the Metal toolchain component and reported `cannot execute tool 'metal'`; `xcodebuild -downloadComponent MetalToolchain` restored it and the same build then succeeded.

### Manifest

The manifest now carries 42 records in 12 groups: 8 native, 15 converted, 8 partial, 11 unsupported, including the new `Emulation services` group (`mtl-emulation-bc-decode`, `-tessellation`, `-fences`, `-sparse`, `-argument-replay`). `BridgeLogicTests.testManifestCounts` and a new `testManifestEmulationServiceRecords` assert the totals and the group's ids.

### Shader retarget tool

```sh
python3 Tools/metal_retarget.py --selftest
```

Result: all rule and rewrite cases pass. A `--strict` scan of the shipped shaders (`Shaders/BCDecode.metal`, `Shaders/Tessellation.metal`) reports zero findings. A corpus smoke test (see docs/COMPAT_SHADER.md) ran the scanner with `--headers` over 104 real `.metal` files from GPUImage3 (BSD), MetalPetal (MIT), and dehesa/sample-metal (MIT): the `.metal` sources are clean, and the only 28 findings are Metal 2 function constants in MetalPetal's shader headers, exactly what the `MSL2-FC` rule exists to catch. The contract is documented in `docs/COMPAT_SHADER.md`.

### Witch launcher integration

MetalBridgeKit.framework (Release, `arm64-apple-ios`, Swift stable ABI) is vendored into the Witch launcher repo at `Natives/resources/Frameworks/MetalBridgeKit.framework` together with its `default.metallib` (BCDecoder resolves it through `Bundle(for:)`). The launcher Makefile gained a `dep_metalbridge` target (rebuilds from `METALBRIDGE_SRC` when present, keeps the vendored copy otherwise; included in the `payload` prerequisites). For the `metal_macos` renderer, `JavaLauncher.m` dlopens the framework `RTLD_GLOBAL` before the JVM starts, exports `WITCH_METAL_BRIDGE_PATH` / `WITCH_METAL_BRIDGE_BUNDLE` for the ported mod, and calls the new `@objc MBProbe.runAllServices()` entry point, which runs all five emulation-service probes on the device and logs a PASS/FAIL line each (`WITCH_METAL_PROBE=0` skips the probes). `MBProbe` lives in `Sources/MetalBridgeKit/Emulation/MBProbe.swift`; the launcher-side uses an `@interface MBProbe` forward declaration and `NSClassFromString` because the launcher binary never links the framework.

### Still not verified

- No iOS device or simulator execution of the new services, Lab UI, or service probes.
- No on-device run yet. An Apple A11 device (Apple GPU family 4) is available to the project owner; family 4 also lacks native BC sampling and hardware tessellation, so the emulation services are the expected path there too.
- No signed installation.
- No performance or thermal measurement.

## Emulation-services extension (2026-10-28)

The following verification was added for the BC decode service, the emulation services, the shader retarget tool, and the Lab service probes.

### Differential BC decode

`Tools/run_bc_differential.sh` compiles `Shaders/BCDecode.metal` with `-std=ios-metal1.2` and a CPU reference built on the vendored bcdec v0.985, then compares texel-by-texel across all seven BC kernels:

```text
BC1: PASS
BC2: PASS
BC3: PASS
BC4 unsigned: PASS
BC4 signed: PASS
BC5 unsigned: PASS
BC5 signed: PASS
BC6H all modes: PASS
BC7: PASS (including randomized seeds 1-4, 32x32)
```

One BC7 correctness bug was found and fixed during this verification: the bit-seek reader consumed the sequential stream state instead of reading the pristine block words; the fix (`origLow`/`origHigh` in the bit stream) is covered by the passing suite. A second, toolchain-level finding: `[[threads_per_grid]]` returns the *padded* dispatch grid, so all kernels now derive the logical grid from explicit params; see docs/COMPAT_SHADER.md.

### Emulation services

- `FenceBridge`: monotonic `signaledValue`, one-shot `notify(atValue:)`, `wait(untilValue:timeout:)`, `syncFromGPU()` mirror of a real `MTLSharedEvent`. Covered by `FenceBridgeTests` (iOS build) and facade test 7 (host run).
- `SparseFallback`: dense zeroed backing, 64-texel pages for rgba8 at 16 KiB pages, page allocate/deallocate with zeroing, mapping-changed event. Covered by `SparseFallbackTests` and facade test 8.
- `ArgumentReplayEncoder`: records buffer/texture/sampler/bytes bindings and replays them into real compute and render encoders; validated by dispatching a recorded BC1 decode and observing the recorded params reach the kernel (pitch-8 check). Covered by `ArgumentReplayEncoderTests` and facade test 9.
- `ServiceProbes.run()`: the Lab's Service Probes section; all five probes (BC1, BC7, Fences, Sparse, Replay) pass on the host rig, and the run is asserted as facade test 10.

### Host facade driver

The macOS app-bundle driver `/tmp/mb_bc_test/bcfacade.app` runs the real framework sources plus the compiled BC kernels and reports:

```text
PASS 1-10: BC1 decode, decodeMip isolation, mip dump, BC7 chain,
           native path, private blit, memoryless rejection, 32x32 mip chain,
           FenceBridge, SparseFallback, ArgumentReplayEncoder, ServiceProbes
ALL FACADE TESTS PASSED
```

This is host-side (Intel Mac) execution of the iOS-targeted facade code, not an A9 run.

### Builds

All three targets rebuild after the extension:

```text
xcodebuild -target MetalBridgeLab -target MetalBridgeKitTests ... BUILD SUCCEEDED
```

### Shader retarget tool

```sh
python3 Tools/metal_retarget.py --selftest
# metal_retarget selftest: all cases passed

python3 Tools/metal_retarget.py Sources/MetalBridgeKit/Shaders --strict
# exit 0: zero findings, zero rewrites on the shipped shaders
```

### Not verified (extension)

- ~~No A9 hardware run; service probes run on the Intel Mac validation rig only.~~ **Superseded 2026-10-28: the service probes ran on-device** (iPhone 8 Plus, A11 Bionic, jailbroken, iOS 16.7.16) through the Witch launcher's `metal_macos` renderer — all five probes PASS in `latestlog.txt` (BC1, BC7, Fences, Sparse, Argument replay). This is the first real-device verification of the emulation services.
- The Lab UI change (Service Probes section) is compiled, not launched.

## macOS-only Metal API shims for third-party natives (2026-10-28)


`Sources/MetalBridgeKit/Shims/MBMetalShims.{h,mm}` extends the facade with the macOS-only surface third-party Metal code needs:

- **Residency sets**: `NSObject` category answering `newResidencySetWithDescriptor:error:` (device) and `addResidencySet:` (queue) plus an `MBResidencySetImpl` class conforming to the `MBResidencySet` protocol shape. On iOS 18+ the real class's own implementation wins the hierarchy lookup and the shim bridges through it; below iOS 18 it emulates (unified memory: bookkeeping only). Callers bind `_OBJC_CLASS_$_MBResidencySetDescriptor` from the framework by compiling with `-DMTLResidencySetDescriptor=MBResidencySetDescriptor` (no symbol collision with Metal's own export on 18+).
- **CAMetalLayer.displaySyncEnabled**: explicitly unavailable in the iOS SDK, so a same-name declaration cannot override it — the shim adds `mbDisplaySyncEnabled` (associated object) and the caller maps the call site with a `-D` macro.
- **MTLCompileOptions.mathMode**: iOS 18+ property; the shim answers `setMathMode:`/`mathMode` on the NSObject level, forwarding to the captured real implementation on 18+ and dropping/storing the flag below.

First on-device run (iPhone 8 Plus, iOS 16.7.16) with the patched jar: the mod's native loaded and ran to `mc_library_new`, which crashed on `-[MTLCompileOptionsInternal setMathMode:]` (`objc_crash_1793258725.txt`) — the missing selector, fixed by the mathMode shim above; this validated the runtime-bind path end to end.

Run 2 (same device, mathMode-shimmed IPA): no crash — the backend booted (`Using graphics backend Metal, using drivers: Metal 3 (mcopt)`, `Apple A11 GPU`), but the app sat on a black screen with an idle log until force-closed. Two defects found in the shim bundle:
- **Mangled shim exports**: the shim's `.mm` is ObjC++, so its C API redefine was compiled with C++ linkage (`__Z32CVDisplayLink…`). The mod link had hidden this behind `-undefined dynamic_lookup` (symbols unresolved → the "vaporize" of the work). Fixed with `extern "C"` in `MBMetalShims.h` around the CVDisplayLink/CGMainDisplayID block to match the header's plain C usage; the checker now confirms unmangled exports (`T _CVDisplayLinkCreateWithCGDisplay`) and the mod links explicitly against `-framework MetalBridgeKit` (no `dynamic_lookup`) so unsatisfied symbols fail the link instead.
- **CVDisplayLink delivery thread**: the shim originally ticked a CADisplayLink on the main run loop, which cannot fire when the owning run loop is blocked (unlike macOS's dedicated CVDisplayLink thread). The shim now spawns a run loop thread (`MBDisplayLinkThreadEntry`) with a `runMode` pump bounded to 20 ms, and falls back to the main run loop if the spawn fails.
- **Bring-up trace**: shim APIs NSLog one-time markers (`[MBMetalShims] …`), and the mod's `mcmetal.m` logs bounded markers (`[mcopt-trace] create/newlib/layerconf/tick/pace/next/present`) before the first 4-20 events of each site, so the next run shows exactly which call a frozen boot stops on.

Run 3 (latestlog 2): the quantum of the hang found — `[mcopt-trace] newlib #1 compile len=819` started, never finished, while the shim's `mathMode` counter showed millions of forwards: `class_getMethodImplementation` returns the **forwarding stub** (non-nil) for a selector the device's runtime class does not have, so the captured-IMP "forward" re-entered the shim itself — a passive infinite loop spinning hundreds of MB of log. Architectural fix: **shim methods never shadow real selectors** — they are mb-named (`setMbMathMode:`, `mbAddResidencySet:`, `mbResidencySetWithDescriptor:error:`) and the callers' sites remap with header macros (`#define mathMode mbMathMode` etc., same pattern as `displaySyncEnabled`); each mb method resolves the real API by `class_getInstanceMethod` (returns NULL when absent — no stub path) at call time. The unbounded shim NSLogs (addResidencySet, displaySyncEnabled) got counters too.
- **CVDisplayLink C API over CADisplayLink**: `CVDisplayLinkCreateWithCGDisplay` / `SetOutputCallback` / `Start` / `Stop` / `Release` + `CGMainDisplayID` (constant id), callback delivered on a private serial queue off the main run loop.

The C symbols are exported (`nm -gU`: 5× `CVDisplayLink*`, `_CGMainDisplayID`, both `MBResidencySet*` classes) and bind at dyld time because the launcher loads the framework `RTLD_GLOBAL` before the JVM.

### mcopt native port (proof of scope)

The mcopt mod's macOS-only native (7187 lines ObjC/C) recompiled for iOS with just those flags: `-fno-objc-arc -O2 -arch arm64 -target arm64-apple-ios16.0 -dynamiclib -include MBMetalShims.h -DMTLResidencySetDescriptor=MBResidencySetDescriptor -undefined dynamic_lookup` — 8/8 TUs compile (only `-Wunguarded-availability-new` warnings, tolerated), link clean (`platform IOS, minos 16.0`), ldid ad-hoc signed, and the dylib is swapped into a patched jar at the fixed `natives/libmcmetal.dylib` resource path so `Native.java` needs no changes to load it.
