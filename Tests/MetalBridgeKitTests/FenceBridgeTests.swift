import XCTest
import Metal
@testable import MetalBridgeKit

/// Tiny thread-safe counter for notification assertions.
final class NotificationCounter {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

final class FenceBridgeTests: XCTestCase {
    private var device: MTLDevice!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        self.device = device
    }

    func testSignaledValueAdvancesMonotonically() {
        let bridge = FenceBridge(device: device)
        let event = bridge.makeEvent(label: "test")
        XCTAssertEqual(event.signaledValue, 0)
        event.signal(5)
        XCTAssertEqual(event.signaledValue, 5)
        event.signal()
        XCTAssertEqual(event.signaledValue, 6)
        // At-or-below values are ignored; the invariant holds.
        event.signal(2)
        XCTAssertEqual(event.signaledValue, 6)
        // Property setter path keeps the same semantics.
        event.setSignaledValue(10)
        XCTAssertEqual(event.signaledValue, 10)
    }

    func testNotifyFiresOnceWhenValueReached() {
        let bridge = FenceBridge(device: device)
        let event = bridge.makeEvent()
        let counter = NotificationCounter()
        event.notify(atValue: 3) {
            counter.increment()
        }
        // Not yet.
        event.signal(2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(counter.value, 0)
        // Reached.
        event.signal(3)
        XCTAssertTrue(event.wait(untilValue: 3, timeout: 1))
        // Handlers are async on the bridge queue; settle before counting.
        bridge.notificationQueue.sync {}
        XCTAssertEqual(counter.value, 1, "notify must fire exactly once")
        // Late notifications already past fire async, once.
        let lateCounter = NotificationCounter()
        event.notify(atValue: 2) {
            lateCounter.increment()
        }
        bridge.notificationQueue.sync {}
        XCTAssertEqual(lateCounter.value, 1, "late notify must fire exactly once")
    }

    func testWaitBlocksUntilValueOrTimeout() {
        let bridge = FenceBridge(device: device)
        let event = bridge.makeEvent()
        // Timeout path.
        let start = Date()
        let reached = event.wait(untilValue: 1, timeout: 0.05)
        XCTAssertFalse(reached)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.04)
        // Signalled path.
        event.signal(1)
        XCTAssertTrue(event.wait(untilValue: 1, timeout: 1))
        // Already past target.
        XCTAssertTrue(event.wait(untilValue: 0))
    }

    func testGPUEventMirror() throws {
        let bridge = FenceBridge(device: device)
        let event = bridge.makeEvent(label: "mirror")
        guard let gpu = event.gpuEvent else {
            throw XCTSkip("MTLSharedEvent unavailable on this device.")
        }
        // The iOS 26 SDK dropped encoder-side signalEvent; the host-side signal
        // path is the writable shared event, mirrored back by syncFromGPU.
        gpu.signaledValue = 7
        event.syncFromGPU()
        XCTAssertEqual(event.signaledValue, 7)
    }
}
