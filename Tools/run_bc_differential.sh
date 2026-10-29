#!/bin/zsh
# Differential BC decode test: GPU kernels (Shaders/BCDecode.metal) vs the vendored
# bcdec reference (third_party/bcdec), texel for texel. Runs on the host GPU; the
# kernel source is the same file the A9 framework ships, compiled here for macOS.
set -e
cd "$(dirname "$0")/.."
OUT=/tmp/mb_bc_test
mkdir -p "$OUT"

xcrun metal -std=macos-metal1.2 -c Sources/MetalBridgeKit/Shaders/BCDecode.metal -o "$OUT/BCDecode.ir" 2>&1
xcrun metallib "$OUT/BCDecode.ir" -o "$OUT/BCDecode.metallib" 2>&1
cc -c third_party/bcdec/bcdec_impl.c -o "$OUT/bcdec_impl.o" -O2 -DBCDEC_BC4BC5_PRECISE -I third_party/bcdec 2>&1
swiftc -O -sdk "$(xcrun -sdk macosx -show-sdk-path)" \
  -import-objc-header Tools/BCDecodeDifferentialTest/bcdec-bridge.h \
  Tools/BCDecodeDifferentialTest/main.swift "$OUT/bcdec_impl.o" \
  -o "$OUT/bc_test" -framework Metal -framework Foundation 2>&1
"$OUT/bc_test" "$OUT/BCDecode.metallib"
