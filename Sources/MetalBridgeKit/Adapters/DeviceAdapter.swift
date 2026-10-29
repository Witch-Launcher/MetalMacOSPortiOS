import Foundation
import Metal

public enum BridgeDeviceLocation: String, CaseIterable {
    case builtIn
    case slot
    case external
}

public struct DeviceAdapter {
    public let device: MTLDevice

    public init(device: MTLDevice) {
        self.device = device
    }

    public var isLowPower: BridgeResult<Bool> {
        .partial(true, note: "iOS exposes only integrated GPUs. This is a platform inference, not the native macOS isLowPower query.")
    }

    public var isHeadless: BridgeResult<Bool> {
        .partial(false, note: "The system default iOS device is display-capable. There is no macOS-style headless GPU selection.")
    }

    public var isRemovable: BridgeResult<Bool> {
        .converted(false, note: "iOS hardware has no removable or external GPU.")
    }

    public var location: BridgeResult<BridgeDeviceLocation> {
        .converted(.builtIn, note: "The iOS system device is built into the device.")
    }

    public var locationNumber: BridgeResult<Int> {
        .converted(0, note: "iOS has a single built-in device location.")
    }

    public var maxTransferRate: BridgeResult<UInt64> {
        .partial(0, note: "iOS does not expose a PCIe transfer rate. Zero means unknown.")
    }

    public var depth24Stencil8PixelFormatSupported: BridgeResult<Bool> {
        .converted(false, note: "The depth24 stencil8 pixel format is unavailable in the iOS SDK.")
    }

    public var peerGroupID: BridgeResult<UInt64> {
        .converted(0, note: "The bridge models the single iOS GPU as one peer group.")
    }

    public var peerIndex: BridgeResult<UInt32> {
        .converted(0, note: "The single iOS GPU has peer index zero.")
    }

    public var peerCount: BridgeResult<UInt32> {
        .converted(1, note: "The bridge exposes one GPU peer on iOS.")
    }

    public var maximizeConcurrentCompilation: BridgeResult<Bool> {
        .unsupported(reason: "shouldMaximizeConcurrentCompilation is a macOS 13.3+ compile scheduling control with no iOS equivalent.")
    }

    public func setMaximizeConcurrentCompilation(_ value: Bool) throws {
        throw BridgeError.unsupported("Concurrent compilation scheduling is not configurable on iOS.")
    }
}

public enum BridgeDeviceEvent: Equatable {
    case added(String)
    case removalRequested(String)
    case removed(String)
}

public struct DeviceTopologyAdapter {
    public let device: MTLDevice

    public init(device: MTLDevice) {
        self.device = device
    }

    public func allDevices() -> BridgeResult<[MTLDevice]> {
        .partial([device], note: "iOS exposes one system GPU through this bridge. Multi-GPU enumeration and hot-plug observation are not available.")
    }

    public func observeDeviceChanges(_ handler: @escaping (BridgeDeviceEvent) -> Void) throws -> AnyObject {
        throw BridgeError.unsupported("Device add/remove notifications are macOS-only. iOS has one built-in GPU and no public hot-plug event stream.")
    }

    public func removeObserver(_ observer: AnyObject) throws {
        throw BridgeError.unsupported("There is no device observer to remove on iOS.")
    }
}
