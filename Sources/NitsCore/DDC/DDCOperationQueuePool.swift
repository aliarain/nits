import Foundation

/// One serial queue per physical display, plus a hold that parks every queue (existing and
/// future) until the caller releases it. WindowServer display enable/disable waits behind
/// an in-flight I2C transaction on the DCP and can freeze the whole machine with it, so the
/// disconnect path holds DDC idle around the transaction.
final class DDCOperationQueuePool: @unchecked Sendable {
    private final class Hold: @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        let timeout: TimeInterval
        var parked = 0

        init(timeout: TimeInterval) {
            self.timeout = timeout
        }
    }

    private let lock = NSLock()
    private var queues: [UInt32: DispatchQueue] = [:]
    private var activeHolds: [Hold] = []

    func queue(for displayID: UInt32) -> DispatchQueue {
        lock.lock()
        if let queue = queues[displayID] {
            lock.unlock()
            return queue
        }
        let queue = DispatchQueue(label: "app.nits.ddc.\(displayID)", qos: .userInitiated)
        queues[displayID] = queue
        let holds = activeHolds
        for hold in holds { hold.parked += 1 }
        lock.unlock()

        for hold in holds {
            queue.async { _ = hold.gate.wait(timeout: .now() + hold.timeout) }
        }
        return queue
    }

    /// Parks all queues. `onIdle` fires once every queue has drained its current work.
    /// The returned closure releases the park; each queue also self-releases after
    /// `timeout` so a lost release can never wedge DDC permanently.
    func hold(timeout: TimeInterval, onIdle: @escaping () -> Void) -> @Sendable () -> Void {
        let hold = Hold(timeout: timeout)

        lock.lock()
        activeHolds.append(hold)
        let existing = Array(queues.values)
        hold.parked = existing.count
        lock.unlock()

        let idle = DispatchGroup()
        for queue in existing {
            idle.enter()
            queue.async {
                idle.leave()
                _ = hold.gate.wait(timeout: .now() + timeout)
            }
        }
        idle.notify(queue: .global(qos: .userInitiated), execute: onIdle)

        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let parked = hold.parked
            hold.parked = 0
            self.activeHolds.removeAll { $0 === hold }
            self.lock.unlock()
            for _ in 0..<parked { hold.gate.signal() }
        }
    }
}
