import Foundation
import Metal

public struct RemoteResourceAdapter {
    public init() {}

    public func remoteStorageBuffer(for buffer: MTLBuffer) throws -> MTLBuffer {
        throw BridgeError.unsupported("remoteStorageBuffer is a macOS peer-GPU resource sharing API. iOS has no public peer-device resource aliasing.")
    }

    public func newRemoteBufferView(for buffer: MTLBuffer, device: MTLDevice) throws -> MTLBuffer {
        throw BridgeError.unsupported("newRemoteBufferViewForDevice is macOS-only. iOS cannot alias a buffer into another GPU's address space.")
    }

    public func remoteStorageTexture(for texture: MTLTexture) throws -> MTLTexture {
        throw BridgeError.unsupported("remoteStorageTexture is macOS-only. iOS has no public cross-GPU texture alias.")
    }

    public func newRemoteTextureView(for texture: MTLTexture, device: MTLDevice) throws -> MTLTexture {
        throw BridgeError.unsupported("newRemoteTextureViewForDevice is macOS-only and has no iOS peer-GPU equivalent.")
    }
}
