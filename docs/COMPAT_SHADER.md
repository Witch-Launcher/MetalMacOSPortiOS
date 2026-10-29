# Shader Compatibility Contract

This document defines the Metal Shading Language subset that MetalBridgeKit guarantees on the Apple A9 baseline (iOS GPU family 3), and how to bring shaders written against Metal 2, 3, or 4 into that subset. The enforcement tool is `Tools/metal_retarget.py`.

## Baseline

- The bridge compiles its own shaders with `-std=ios-metal1.2`. `Shaders/BCDecode.metal` and `Shaders/Tessellation.metal` compile under that standard with the host toolchain (Xcode 26.3, iOS SDK 26.2, macOS 26.2) and run on the Intel Metal validation rig and in the differential harness.
- A9 does not provide Metal 2.2+ feature surfaces: no mesh or object shaders, no ray tracing, no argument buffers, no function constants, no 64-bit atomics, no raster-order groups.
- Capability boundaries are probed at runtime through `BridgeCapabilities`; shaders must not assume Metal 3/4 hardware features.

## Padded-grid pitfall

`[[threads_per_grid]]` is a Metal 2 attribute, but the older `-std=ios-metal1.2` compiler still accepts it. That is worse than a compile error: in the bridge's differential harness, dispatching with `dispatchThreads` rounds the grid up to whole threadgroups, and `[[threads_per_grid]]` returned the *padded* grid size, not the requested one. Threads beyond the logical grid passed out-of-bounds guards and wrote outside the output.

The bridge's own kernels therefore derive the logical grid from an explicit uniform (`params.widthPixels`, `params.heightPixels`) instead of the attribute. External shaders must do the same; `Tools/metal_retarget.py` performs that rewrite mechanically.

## Reserved buffer slots

The rewrite reserves these buffer indices for grid-size uniforms. Host code binds an 8-byte `uint2` with the same values it passed to `dispatchThreads`.

| Slot | Replaces | Contents |
| --- | --- | --- |
| `buffer(29)` | `[[threads_per_grid]]` | `uint2` grid size in threads |
| `buffer(30)` | `[[threadgroups_per_grid]]` | `uint2` grid size in threadgroups |
| `buffer(31)` | `[[threads_per_threadgroup]]` | `uint2` threadgroup size in threads |

The rewrite reuses the shader author's parameter name for the prologue value, so the kernel body is untouched.

## Tool

```sh
# Report only:
python3 Tools/metal_retarget.py Sources/MyGame/Shaders

# Report and write <stem>.compat.metal next to each rewritten file:
python3 Tools/metal_retarget.py Sources/MyGame/Shaders

# Also scan .h shader headers; Metal 2 function constants and argument-buffer
# structs frequently live there behind preprocessor guards:
python3 Tools/metal_retarget.py Sources/MyGame/Shaders --headers

# Fail the build when any unsupported or partial construct remains:
python3 Tools/metal_retarget.py Sources/MyGame/Shaders --strict
```

- Paths may be `.metal` files or directories (scanned recursively).
- Findings print as `path:line: [severity] rule: message`.
- Files without findings or rewrites are not modified.
- `--json` emits a machine-readable report.
- `--selftest` runs the built-in rule and rewrite tests.

The tool is a scanner plus two validated mechanical rewrites. It is not a full MSL transpiler; constructs it cannot rewrite are reported so a human or the runtime emulation layer can handle them.

## Rules

### Rewrites (applied mechanically)

| Rule | Detects | Action |
| --- | --- | --- |
| `MSL2-TPG` | `[[threads_per_grid]]` | Parameter removed; `constant uint2& mb_threads_per_grid [[buffer(29)]]` appended; `TYPE name = mb_threads_per_grid;` inserted as the body's first statement. |
| `MSL2-TGPG` | `[[threadgroups_per_grid]]` | Same shape with `buffer(30)`. |
| `MSL2-TPTG` | `[[threads_per_threadgroup]]` | Same shape with `buffer(31)`. |
| Namespace strip | `metal::math::`, `metal::geometric::`, `metal::common::`, bare `metal::` | Mapped to the global MSL 1.2 equivalents (`metal::math::floor` → `floor`). `metal::raytracing` is never stripped; it is reported as unsupported. |

### Unsupported (reported; no rewrite)

| Rule | Detects | Guidance |
| --- | --- | --- |
| `MSL3-RT` | `metal::raytracing`, `ray_data`, `intersector`, `acceleration_structure`, `[[intersection]]` | Re-implement intersection logic on the CPU or as compute rasterization. No A9 path exists. |
| `MSL3-MESH` | `[[mesh]]`, `mesh<`, `object void`, `metal::mesh` | Use vertex/fragment pipelines; tessellation goes through `TessellationEmulator`. |
| `MSL2-FC` | `[[function_constant(N)]]` | Specialize by compiling pipeline variants at build time. |
| `MSL2-MTPT` | `[[max_total_threads_per_threadgroup(N)]]` | State the bound in the host's launch math. |
| `MSL2-TGMEM` | `[[threadgroup(N)]]` parameters | Declare threadgroup storage inside the kernel with `threadgroup T name[N];`. |
| `MSL2-ARG` | `[[argument]]` structs | Use explicit `[[buffer(n)]]`/`[[texture(n)]]` indices; `ArgumentReplayEncoder` covers the host side of recorded bindings. |
| `MSL2-ROG` | `[[raster_order_group(N)]]` | Needs imageblocks (Apple GPU family 7). Remove; correctness must not depend on it. |
| `MSL2-EFT` | `[[early_fragment_tests]]` | Set depth/stencil test behavior through the pipeline descriptor. |
| `MSL3-ATOM64` | `atomic_(u?long\|u?int64_t\|...)` | Restructure around 32-bit atomics or a per-cell spin buffer. |

### Partial (reported; runtime-gated)

| Rule | Detects | Guidance |
| --- | --- | --- |
| `MSL2-SIMD` | `[[thread_index_in_simdgroup]]`, `[[simdgroups_in_threadgroup]]`, `simd_*` functions | Not guaranteed on the A9 baseline; gate on runtime capability or restructure with threadgroup memory. |
| `MSL3-FP16` | `float16_t` | FP16 arithmetic needs Apple GPU family 7; on A9 use `half` only as a storage format. |
| `MSL2-RWTEX` | `access::read_write` | Read-write textures are a tier-2 feature; confirm through `BridgeCapabilities` before binding. |

## Runtime emulation the bridge provides

Shader-side rewrites are only half of the story. The bridge emulates the following macOS-side runtime behavior so a retargeted engine's host code does not need per-API changes:

| Bridge service | Emulates | Location |
| --- | --- | --- |
| `BCDecoder` | BC1-BC5, BC6H, BC7 texture creation from compressed payloads | `Emulation/BCDecode/BCDecoder.swift`, compute kernels in `Shaders/BCDecode.metal` |
| `TessellationEmulator` | tessellation stage via compute pre-pass + draw call generation | `Emulation/Tessellation/TessellationEmulator.swift`, `Shaders/Tessellation.metal` |
| `FenceBridge` | MTLSharedEvent-style fences with notify/wait | `Emulation/Fences/FenceBridge.swift` |
| `SparseFallback` | sparse texture mapping as dense zeroed backing with page tracking | `Emulation/Sparse/SparseFallback.swift` |
| `ArgumentReplayEncoder` | argument-buffer-style recorded bindings replayed into ordinary encoders | `Emulation/ArgumentBuffers/ArgumentReplayEncoder.swift` |

Sparse textures through `SparseFallback` are dense: allocation is tracked per page, pages zero on deallocation, and a mapping-changed event advances, but memory consumption equals a fully-resident texture. Shaders cannot index sparse pages directly.

## Verification status

- `python3 Tools/metal_retarget.py --selftest` passes (rewrite shape, comment masking, namespace mapping, rule detection, line numbers).
- The shipped shaders (`Shaders/BCDecode.metal`, `Shaders/Tessellation.metal`) report zero findings under `--strict`.
- The `[[threads_per_grid]]` rewrite mirrors the change already applied and differentially verified inside `Shaders/BCDecode.metal` (all BC kernels derive the grid from `params`); the rewritten fixture output is compile-checked by the same `-std=ios-metal1.2` standard only when consumed by the game's own build.
- A corpus smoke test ran the scanner (with `--headers`) over 104 `.metal` files from three open-source projects: GPUImage3 (BSD), MetalPetal (MIT), and dehesa/sample-metal (MIT). The `.metal` sources are clean of A9-unsafe constructs, and the only 28 findings are `MSL2-FC` in MetalPetal's `MTIShaderFunctionConstants.h` — Metal 2 function constants declared in headers behind `#ifdef __METAL_VERSION__` guards, which is exactly the construct the rule exists to catch.
- Not verified: a full game shader corpus. The rule set covers the constructs the bridge hit or could enumerate from the SDK surface; unknown constructs fail loudly in the report rather than silently rewriting.
