import Foundation

/// Serialize complete RPC messages off the input/UI queue. Individual messages
/// must not interleave their HID fragments. Connection invalidation skips queued
/// messages and drains the current one before its IOHIDDevice is closed.
/// The only shared mutable state is generation, protected by lock.
final class HIDWriteQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cc.worklouder.hid-writes", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation
    }

    func enqueue(_ operation: @escaping (UInt64) -> Void) {
        lock.lock(); let token = generation; lock.unlock()
        queue.async(execute: DispatchWorkItem { [self] in
            guard isCurrent(token) else { return }
            operation(token)
        })
    }

    /// Reserved for existing synchronous callers, notably sleep/off flushing.
    func sync<T>(_ operation: () -> T) -> T {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync(execute: operation)
    }

    func invalidateAndDrain() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        lock.lock(); generation &+= 1; lock.unlock()
        // A running write never waits on the main queue. Finish its complete
        // message before closing the transport; never cut a JSON frame in half.
        queue.sync {}
    }
}
