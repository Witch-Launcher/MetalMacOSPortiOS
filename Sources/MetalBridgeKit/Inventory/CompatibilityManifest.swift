import Foundation

public enum CompatibilityGroup: String, CaseIterable {
    case nativeCommon
    case deviceTopology
    case deviceProperties
    case storage
    case synchronization
    case barriers
    case pixelFormats
    case remoteResources
    case featureSets
    case heaps
    case commandBuffer
    case emulationServices

    public var title: String {
        switch self {
        case .nativeCommon: return "Common APIs used natively"
        case .deviceTopology: return "Device topology and notifications"
        case .deviceProperties: return "Device properties"
        case .storage: return "Storage modes and buffer updates"
        case .synchronization: return "Blit synchronization"
        case .barriers: return "Barriers"
        case .pixelFormats: return "Pixel formats"
        case .remoteResources: return "Peer-GPU resources"
        case .featureSets: return "Feature sets"
        case .heaps: return "Heap types"
        case .commandBuffer: return "Command-buffer errors"
        case .emulationServices: return "Emulation services"
        }
    }
}

public struct CompatibilityRecord {
    public let id: String
    public let group: CompatibilityGroup
    public let name: String
    public let macOSAvailability: String
    public let iOSAvailability: String
    public let status: BridgeStatus
    public let implementation: String
    public let limitation: String
    public let sourceHeader: String
    public let documentationURL: URL?

    public static let metalDocumentation = URL(string: "https://developer.apple.com/documentation/metal")!

    public init(id: String,
                group: CompatibilityGroup,
                name: String,
                macOSAvailability: String,
                iOSAvailability: String,
                status: BridgeStatus,
                implementation: String,
                limitation: String,
                sourceHeader: String,
                documentationURL: URL? = CompatibilityRecord.metalDocumentation) {
        self.id = id
        self.group = group
        self.name = name
        self.macOSAvailability = macOSAvailability
        self.iOSAvailability = iOSAvailability
        self.status = status
        self.implementation = implementation
        self.limitation = limitation
        self.sourceHeader = sourceHeader
        self.documentationURL = documentationURL
    }
}

public enum CompatibilityManifest {
    public static let records: [CompatibilityRecord] = [
        CompatibilityRecord(id: "mtl-device-default", group: .nativeCommon, name: "MTLCreateSystemDefaultDevice", macOSAvailability: "10.11+", iOSAvailability: "8.0+", status: .native, implementation: "MetalBridge resolves the system device through the public iOS API.", limitation: "None; one system device is expected.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-buffer", group: .nativeCommon, name: "MTLDevice.makeBuffer(length:options:)", macOSAvailability: "10.11+", iOSAvailability: "8.0+", status: .native, implementation: "StorageModeAdapter maps the requested storage mode and calls the native API.", limitation: "Managed requests are converted to shared storage.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-texture", group: .nativeCommon, name: "MTLDevice.makeTexture(descriptor:)", macOSAvailability: "10.11+", iOSAvailability: "8.0+", status: .native, implementation: "The bridge creates textures with an adapted MTLTextureDescriptor.", limitation: "Managed requests are converted to shared storage.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-command-queue", group: .nativeCommon, name: "MTLCommandQueue", macOSAvailability: "10.11+", iOSAvailability: "8.0+", status: .native, implementation: "MetalBridge.makeCommandQueue wraps the native queue factory.", limitation: "No additional limitation.", sourceHeader: "MTLCommandQueue.h"),
        CompatibilityRecord(id: "mtl-blit-encoder", group: .nativeCommon, name: "MTLBlitCommandEncoder", macOSAvailability: "10.11+", iOSAvailability: "8.0+", status: .native, implementation: "Used by the synchronization adapter and its callers.", limitation: "The macOS-only synchronize methods are adapters, not native calls.", sourceHeader: "MTLBlitCommandEncoder.h"),
        CompatibilityRecord(id: "mtl-render-encoder", group: .nativeCommon, name: "MTLRenderCommandEncoder", macOSAvailability: "10.11+", iOSAvailability: "8.0+", status: .native, implementation: "Used by the render probe and barrier adapter.", limitation: "Render-target barrier scope is partial on iOS.", sourceHeader: "MTLRenderCommandEncoder.h"),
        CompatibilityRecord(id: "mtl-supports-family", group: .nativeCommon, name: "MTLDevice.supportsFamily(_:)", macOSAvailability: "10.15+", iOSAvailability: "13.0+", status: .native, implementation: "BridgeCapabilities probes Apple families on iOS 13 and newer.", limitation: "Apple GPU family numbers are not a device-model identifier.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-supports-feature-set", group: .nativeCommon, name: "MTLDevice.supportsFeatureSet(_:)", macOSAvailability: "10.11+", iOSAvailability: "8.0-16.0 (deprecated)", status: .native, implementation: "BridgeCapabilities uses the legacy probe on iOS 12.", limitation: "Deprecated after iOS 16; only the iOS 12 fallback path uses it.", sourceHeader: "MTLDevice.h"),

        CompatibilityRecord(id: "mtl-all-devices", group: .deviceTopology, name: "MTLCopyAllDevicesWithObserver(observer:handler:)", macOSAvailability: "10.13+", iOSAvailability: "Unavailable", status: .partial, implementation: "allDevices() returns the single system device as a one-element array.", limitation: "No multi-GPU enumeration or hot-plug observer; the one-device result is a platform reduction.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-observer-remove", group: .deviceTopology, name: "MTLRemoveDeviceObserver(_:)", macOSAvailability: "10.13+", iOSAvailability: "Unavailable", status: .unsupported, implementation: "Throws BridgeError.unsupported.", limitation: "No observer can be installed on iOS.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-notifications", group: .deviceTopology, name: "MTLDeviceWasAdded/RemovalRequested/WasRemovedNotification", macOSAvailability: "10.13+", iOSAvailability: "Unavailable", status: .unsupported, implementation: "No callback is synthesized.", limitation: "iOS has one built-in GPU. Emitting fake add/remove events would misrepresent the platform.", sourceHeader: "MTLDevice.h"),

        CompatibilityRecord(id: "mtl-device-low-power", group: .deviceProperties, name: "MTLDevice.isLowPower", macOSAvailability: "10.11+", iOSAvailability: "Unavailable", status: .partial, implementation: "Returns true as an integrated-GPU platform inference.", limitation: "The value is not obtained from the macOS property; it describes the iOS power model.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-headless", group: .deviceProperties, name: "MTLDevice.isHeadless", macOSAvailability: "10.11+", iOSAvailability: "Unavailable", status: .partial, implementation: "Returns false for the system device.", limitation: "iOS has no macOS-style headless device selection.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-removable", group: .deviceProperties, name: "MTLDevice.isRemovable", macOSAvailability: "10.13+", iOSAvailability: "Unavailable", status: .converted, implementation: "Returns false.", limitation: "iOS devices have no removable GPU.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-location", group: .deviceProperties, name: "MTLDevice.location", macOSAvailability: "10.15+", iOSAvailability: "Unavailable", status: .converted, implementation: "Returns BridgeDeviceLocation.builtIn.", limitation: "There is no slot or external location on iOS.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-location-number", group: .deviceProperties, name: "MTLDevice.locationNumber", macOSAvailability: "10.15+", iOSAvailability: "Unavailable", status: .converted, implementation: "Returns 0.", limitation: "Single built-in location.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-max-transfer-rate", group: .deviceProperties, name: "MTLDevice.maxTransferRate", macOSAvailability: "10.15+", iOSAvailability: "Unavailable", status: .partial, implementation: "Returns 0 to mean unknown.", limitation: "iOS exposes no PCIe transfer rate.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-depth24-stencil", group: .deviceProperties, name: "MTLDevice.isDepth24Stencil8PixelFormatSupported", macOSAvailability: "10.11+", iOSAvailability: "Unavailable", status: .converted, implementation: "Returns false.", limitation: "The corresponding pixel format is unavailable in the iOS SDK.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-peer-group", group: .deviceProperties, name: "MTLDevice.peerGroupID", macOSAvailability: "10.15+", iOSAvailability: "Unavailable", status: .converted, implementation: "Returns 0.", limitation: "The single iOS GPU is modeled as one peer group.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-peer-index", group: .deviceProperties, name: "MTLDevice.peerIndex", macOSAvailability: "10.15+", iOSAvailability: "Unavailable", status: .converted, implementation: "Returns 0.", limitation: "Single peer.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-peer-count", group: .deviceProperties, name: "MTLDevice.peerCount", macOSAvailability: "10.15+", iOSAvailability: "Unavailable", status: .converted, implementation: "Returns 1.", limitation: "Single peer; no multi-GPU peer group exists on iOS.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-device-concurrent-compilation", group: .deviceProperties, name: "MTLDevice.shouldMaximizeConcurrentCompilation", macOSAvailability: "13.3+", iOSAvailability: "Unavailable", status: .unsupported, implementation: "Query and setter throw or return an unsupported result.", limitation: "No iOS compile scheduling control exists.", sourceHeader: "MTLDevice.h"),

        CompatibilityRecord(id: "mtl-storage-managed", group: .storage, name: "MTLStorageMode.managed", macOSAvailability: "10.11+", iOSAvailability: "Unavailable", status: .converted, implementation: "Mapped to MTLStorageMode.shared.", limitation: "Managed storage has explicit CPU/GPU synchronization on macOS. Shared storage is coherent on iOS.", sourceHeader: "MTLResource.h"),
        CompatibilityRecord(id: "mtl-buffer-did-modify-range", group: .storage, name: "MTLBuffer.didModifyRange(_:)", macOSAvailability: "10.11+", iOSAvailability: "Unavailable", status: .converted, implementation: "Validates the range and returns .noActionRequired for shared buffers.", limitation: "Private and memoryless buffers throw; no upload is fabricated.", sourceHeader: "MTLBuffer.h"),

        CompatibilityRecord(id: "mtl-blit-synchronize-resource", group: .synchronization, name: "MTLBlitCommandEncoder.synchronizeResource(_:)", macOSAvailability: "10.11+", iOSAvailability: "Unavailable", status: .converted, implementation: "Returns .noActionRequired for shared resources.", limitation: "Private and memoryless resources throw; managed storage is mapped to shared.", sourceHeader: "MTLBlitCommandEncoder.h"),
        CompatibilityRecord(id: "mtl-blit-synchronize-texture", group: .synchronization, name: "MTLBlitCommandEncoder.synchronizeTexture(_:slice:level:)", macOSAvailability: "10.11+", iOSAvailability: "Unavailable", status: .converted, implementation: "Validates slice and level, then applies the shared-resource adapter.", limitation: "Private and memoryless textures throw.", sourceHeader: "MTLBlitCommandEncoder.h"),

        CompatibilityRecord(id: "mtl-barrier-render-targets", group: .barriers, name: "MTLBarrierScope.renderTargets", macOSAvailability: "10.14+", iOSAvailability: "Unavailable", status: .partial, implementation: "On iOS 16+, emits a texture-scope memory barrier.", limitation: "The scope is not identical; iOS 12-15 throw unsupported.", sourceHeader: "MTLCommandEncoder.h"),
        CompatibilityRecord(id: "mtl-texture-barrier", group: .barriers, name: "MTLRenderCommandEncoder.textureBarrier()", macOSAvailability: "10.11-10.14 (deprecated)", iOSAvailability: "Unavailable", status: .partial, implementation: "Maps to the same texture-scope barrier adapter on iOS 16+.", limitation: "Deprecated macOS API; no exact iOS equivalent on older versions.", sourceHeader: "MTLRenderCommandEncoder.h"),

        CompatibilityRecord(id: "mtl-pixelformat-depth24-stencil", group: .pixelFormats, name: "MTLPixelFormat.depth24Unorm_stencil8", macOSAvailability: "10.11+", iOSAvailability: "Unavailable", status: .converted, implementation: "Maps to MTLPixelFormat.depth32Float_stencil8.", limitation: "Higher depth precision and a different memory footprint.", sourceHeader: "MTLPixelFormat.h"),
        CompatibilityRecord(id: "mtl-pixelformat-x24-stencil", group: .pixelFormats, name: "MTLPixelFormat.x24_stencil8", macOSAvailability: "10.12+", iOSAvailability: "Unavailable", status: .unsupported, implementation: "Throws or returns an unsupported result.", limitation: "No public iOS X24 stencil-only format.", sourceHeader: "MTLPixelFormat.h"),

        CompatibilityRecord(id: "mtl-buffer-remote-storage", group: .remoteResources, name: "MTLBuffer.remoteStorageBuffer", macOSAvailability: "10.15+", iOSAvailability: "Unavailable", status: .unsupported, implementation: "Throws BridgeError.unsupported.", limitation: "No peer-GPU buffer alias on iOS.", sourceHeader: "MTLBuffer.h"),
        CompatibilityRecord(id: "mtl-buffer-remote-view", group: .remoteResources, name: "MTLBuffer.newRemoteBufferViewForDevice(_:)", macOSAvailability: "10.15+", iOSAvailability: "Unavailable", status: .unsupported, implementation: "Throws BridgeError.unsupported.", limitation: "No cross-device address-space alias on iOS.", sourceHeader: "MTLBuffer.h"),
        CompatibilityRecord(id: "mtl-texture-remote-storage", group: .remoteResources, name: "MTLTexture.remoteStorageTexture", macOSAvailability: "10.15+", iOSAvailability: "Unavailable", status: .unsupported, implementation: "Throws BridgeError.unsupported.", limitation: "No peer-GPU texture alias on iOS.", sourceHeader: "MTLTexture.h"),
        CompatibilityRecord(id: "mtl-texture-remote-view", group: .remoteResources, name: "MTLTexture.newRemoteTextureViewForDevice(_:)", macOSAvailability: "10.15+", iOSAvailability: "Unavailable", status: .unsupported, implementation: "Throws BridgeError.unsupported.", limitation: "No cross-device texture view on iOS.", sourceHeader: "MTLTexture.h"),

        CompatibilityRecord(id: "mtl-feature-set-macos", group: .featureSets, name: "MTLFeatureSet macOS GPU families", macOSAvailability: "10.11+", iOSAvailability: "Unavailable", status: .unsupported, implementation: "Reported as not applicable.", limitation: "macOS feature-set values are not iOS capability identifiers.", sourceHeader: "MTLDevice.h"),
        CompatibilityRecord(id: "mtl-heap-sparse", group: .heaps, name: "MTLHeapType.sparse", macOSAvailability: "11.0+", iOSAvailability: "Unavailable", status: .unsupported, implementation: "Reported as unavailable.", limitation: "The sparse heap type is not exposed to iOS apps.", sourceHeader: "MTLHeap.h"),
        CompatibilityRecord(id: "mtl-command-buffer-device-removed", group: .commandBuffer, name: "MTLCommandBufferError.deviceRemoved", macOSAvailability: "10.13+", iOSAvailability: "Unavailable", status: .unsupported, implementation: "Reported as not applicable.", limitation: "iOS has no public device-removal error path.", sourceHeader: "MTLCommandBuffer.h"),

        CompatibilityRecord(id: "mtl-emulation-bc-decode", group: .emulationServices, name: "BC1-BC5, BC6H, BC7 texture creation", macOSAvailability: "10.11+", iOSAvailability: "BC sampling needs Apple7", status: .converted, implementation: "BCDecoder decodes compressed payloads to RGBA through compute kernels bit-exact against bcdec v0.985.", limitation: "Decoded textures cost 4-8 bytes per pixel instead of native compressed sampling; payloads must be fed to makeTexture(rawData:).", sourceHeader: "Shaders/BCDecode.metal"),
        CompatibilityRecord(id: "mtl-emulation-tessellation", group: .emulationServices, name: "Tessellation stage", macOSAvailability: "10.11+ (MTLPatch)", iOSAvailability: "No tessellation stage", status: .partial, implementation: "TessellationEmulator runs a compute pre-pass over control points and generates expanded draws.", limitation: "Not the macOS tessellation pipeline stage; tess factors clamp to the family limit and domain programs come from the bridge kernels.", sourceHeader: "Shaders/Tessellation.metal"),
        CompatibilityRecord(id: "mtl-emulation-fences", group: .emulationServices, name: "MTLSharedEvent-style fences", macOSAvailability: "10.14+", iOSAvailability: "MTLSharedEvent exists on iOS", status: .converted, implementation: "FenceBridge provides monotonic CPU events with notify/wait over a shared event.", limitation: "Encoder-side GPU signaling is not synthesized; the GPU mirror reflects the shared event's signaledValue only.", sourceHeader: "Emulation/Fences/FenceBridge.swift"),
        CompatibilityRecord(id: "mtl-emulation-sparse", group: .emulationServices, name: "Sparse texture mapping", macOSAvailability: "11.0+", iOSAvailability: "No sparse heaps", status: .partial, implementation: "SparseFallback tracks page allocation over a dense zeroed backing and advances a mapping-changed event.", limitation: "Memory equals a fully-resident texture; there is no residency behavior and shaders cannot index pages.", sourceHeader: "Emulation/Sparse/SparseFallback.swift"),
        CompatibilityRecord(id: "mtl-emulation-argument-replay", group: .emulationServices, name: "Argument-buffer-style bindings", macOSAvailability: "10.13+", iOSAvailability: "Tier-1 argument buffers need Apple4+", status: .converted, implementation: "ArgumentReplayEncoder records buffer/texture/sampler/bytes bindings and replays them into ordinary encoders.", limitation: "No argument-buffer structs in shaders; renderers bind explicit indices and replay on the host side.", sourceHeader: "Emulation/ArgumentBuffers/ArgumentReplayEncoder.swift")
    ]

    public static func count(for status: BridgeStatus) -> Int {
        records.filter { $0.status == status }.count
    }

    public static func records(in group: CompatibilityGroup) -> [CompatibilityRecord] {
        records.filter { $0.group == group }
    }

    public static var groupedRecords: [(group: CompatibilityGroup, records: [CompatibilityRecord])] {
        CompatibilityGroup.allCases.compactMap { group in
            let items = records(in: group)
            return items.isEmpty ? nil : (group, items)
        }
    }
}
