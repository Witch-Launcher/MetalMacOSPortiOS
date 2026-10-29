#!/bin/zsh
# Build and run the macOS facade driver: compiles the real framework Swift sources
# plus the BC decode kernels (compiled for macOS with -std=macos-metal1.2) and the
# MSL 1.2 probe shader into a one-shot .app bundle, then runs it.
#
# This is the host validation path for the MetalBridge facade. The iOS test bundle
# compiles for device but cannot run on this Intel host, so this driver is where the
# facade's runtime behavior is actually exercised.
set -e
cd "$(dirname "$0")/../.."
OUT=build/facade-driver
APP="$OUT/FacadeDriver.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun metal -std=macos-metal1.2 -c Sources/MetalBridgeKit/Shaders/BCDecode.metal -o "$OUT/BCDecode.ir" 2>&1
xcrun metal -std=macos-metal1.2 -c Shaders/Probe.metal -o "$OUT/Probe.ir" 2>&1
xcrun metallib "$OUT/BCDecode.ir" "$OUT/Probe.ir" -o "$APP/Contents/Resources/default.metallib" 2>&1

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>FacadeDriver</string>
    <key>CFBundleIdentifier</key>
    <string>dev.metalbridge.facadesdriver</string>
    <key>CFBundleName</key>
    <string>FacadeDriver</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
</dict>
</plist>
PLIST

# Explicit source list: zsh does not word-split variables, and the driver must be
# the only main.swift compiled with -module-name MetalBridgeKit.
swiftc -module-name MetalBridgeKit \
  Sources/MetalBridgeKit/Core/*.swift \
  Sources/MetalBridgeKit/Adapters/*.swift \
  Sources/MetalBridgeKit/Emulation/BCDecode/BCDecoder.swift \
  Sources/MetalBridgeKit/Emulation/MSAAPolicy.swift \
  Sources/MetalBridgeKit/Emulation/Tessellation/TessellationEmulator.swift \
  Sources/MetalBridgeKit/Emulation/Sparse/SparseFallback.swift \
  Sources/MetalBridgeKit/Emulation/Fences/FenceBridge.swift \
  Sources/MetalBridgeKit/Emulation/ArgumentBuffers/ArgumentReplayEncoder.swift \
  Sources/MetalBridgeKit/Emulation/ServiceProbes.swift \
  Sources/MetalBridgeKit/Mac/*.swift \
  Sources/MetalBridgeKit/Inventory/CompatibilityManifest.swift \
  Tools/FacadeDriver/main.swift \
  -o "$APP/Contents/MacOS/FacadeDriver" 2>&1

"$APP/Contents/MacOS/FacadeDriver"
