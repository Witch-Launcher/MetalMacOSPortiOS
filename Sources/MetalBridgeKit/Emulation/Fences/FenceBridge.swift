import Foundation
import Metal

/// macOS-style shared-event fences on iOS.
///
/// macOS apps synchronize CPU work with GPU progress through `MTLSharedEvent`
/// plus a `MTLSharedEventListener` (dispatch-source notifications). The listener
/// type is macOS-only, so the bridge reproduces its contract with a CPU
/// condition-variable event:
///
/// - `Event` owns a monotonically increasing 64-bit value with the same
///   `signaledValue` property shape as `MTLSharedEvent`, so ported code keeps
///   its syntax.
/// - `notify(atValue:handler:)` queues the handler exactly once when the value
///   is reached (the macOS listener contract), on the bridge's serial queue.
/// - `wait(untilValue:timeout:)` blocks like `MTLSharedEvent` waits on macOS.
/// - For GPU-side progress the event lazily exposes a real `MTLSharedEvent`;
///   command buffers can signal/wait it natively, and `syncFromGPU()` mirrors
///   completed GPU values into the CPU value and fires pending notifications.
///
/// Documented differences versus macOS:
/// - Signaling a value at or below the current value is ignored instead of
///   raising; the monotonic invariant holds either way.
/// - Notification handlers run on the bridge's serial queue instead of the
///   app-provided `MTLSharedEventListener` dispatch queue.
public final class FenceBridge {
    /// Serial queue every notification handler is dispatched on.
    public let notificationQueue: DispatchQueue
    private let device: MTLDevice

    public init(device: MTLDevice) {
        self.device = device
        self.notificationQueue = DispatchQueue(label: "dev.metalbridge.fencebridge.notifications")
    }

    public func makeEvent(label: String? = nil) -> Event {
        return Event(device: device, label: label, notificationQueue: notificationQueue)
    }

    /// One shared event: CPU value, pending notifications, optional GPU mirror.
    public final class Event {
        public let label: String?
        private let condition: NSCondition
        private let notificationQueue: DispatchQueue
        private let device: MTLDevice
        private var _signaledValue: UInt64 = 0
        private var completions: [(target: UInt64, handler: () -> Void)] = []
        private var gpuEventStorage: MTLSharedEvent?

        fileprivate init(device: MTLDevice, label: String?, notificationQueue: DispatchQueue) {
            self.device = device
            self.label = label
            self.condition = NSCondition()
            self.notificationQueue = notificationQueue
        }

        /// The current value, monotonically increasing.
        public var signaledValue: UInt64 {
            condition.lock()
            defer { condition.unlock() }
            return _signaledValue
        }

        /// Advances the value. Passing a value at or below the current one is
        /// ignored (macOS raises; the bridge preserves the monotonic invariant).
        public func signal(_ value: UInt64) {
            self.setSignaledValue(value)
        }

        /// Advances the value by one (the `event.signaledValue += 1` idiom).
        public func signal() {
            self.setSignaledValue(self.signaledValue &+ 1)
        }

        /// Property setter path for `event.signaledValue = v`.
        public func setSignaledValue(_ value: UInt64) {
            condition.lock()
            guard value > _signaledValue else {
                condition.unlock()
                return
            }
            _signaledValue = value
            var due: [() -> Void] = []
            var remaining: [(target: UInt64, handler: () -> Void)] = []
            for completion in completions {
                if completion.target <= _signaledValue {
                    due.append(completion.handler)
                } else {
                    remaining.append(completion)
                }
            }
            completions = remaining
            condition.broadcast()
            condition.unlock()
            for handler in due {
                notificationQueue.async(execute: handler)
            }
        }

        /// Queues `handler` once, after the value reaches `target`. Fires
        /// immediately (async) when the value is already there.
        public func notify(atValue target: UInt64, handler: @escaping () -> Void) {
            condition.lock()
            let already = _signaledValue >= target
            if !already {
                completions.append((target, handler))
            }
            condition.unlock()
            if already {
                notificationQueue.async(execute: handler)
            }
        }

        /// Blocks until the value reaches `target`. Returns `true` when reached,
        /// `false` when `timeout` (seconds) elapsed first. Passing `nil` waits
        /// unbounded, matching macOS.
        @discardableResult
        public func wait(untilValue target: UInt64, timeout: TimeInterval? = nil) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let deadline = timeout.map { Date().addingTimeInterval($0) }
            while _signaledValue < target {
                let reached: Bool
                if let deadline = deadline {
                    reached = condition.wait(until: deadline)
                } else {
                    condition.wait()
                    reached = true
                }
                if !reached && _signaledValue < target {
                    return false
                }
            }
            return true
        }

        /// A real `MTLSharedEvent` on the device, created on first access. Command
        /// buffers can signal/wait it natively; call `syncFromGPU()` after those
        /// buffers complete to mirror GPU progress into this event.
        public var gpuEvent: MTLSharedEvent? {
            condition.lock()
            defer { condition.unlock() }
            if let gpu = gpuEventStorage {
                return gpu
            }
            guard let gpu = device.makeSharedEvent() else {
                return nil
            }
            gpuEventStorage = gpu
            return gpu
        }

        /// Mirrors the GPU event's signaled value into the CPU value and fires
        /// any notifications that are now due. Call after command buffers that
        /// signal `gpuEvent` have completed.
        public func syncFromGPU() {
            guard let gpu = gpuEvent else { return }
            let completed = gpu.signaledValue
            if completed > self.signaledValue {
                self.setSignaledValue(completed)
            }
        }
    }
}
