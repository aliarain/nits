import Foundation

/// Runs a blocking CoreGraphics/WindowServer call off the caller's thread and stops
/// waiting after `seconds`. The timeout cannot cancel the underlying call (CoreGraphics
/// has no cancellation), it only guarantees the caller is never wedged by it.
public func withTimeout<T: Sendable>(
    seconds: Double,
    fallback: T,
    operation: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { continuation in
        let once = ResumeOnce()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = operation()
            if once.claim() {
                continuation.resume(returning: result)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if once.claim() {
                continuation.resume(returning: fallback)
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}

/// A tiny latest-wins pump. Callers submit values faster than the hardware can take
/// them; the pump runs one write at a time, always with the newest value, with a
/// pacing floor between writes. This is what keeps a slider drag from flooding I2C.
public actor LatestValuePump {
    public typealias Body = @Sendable (Double) async -> Void

    private var target: Double?
    private var running = false
    private let minimumInterval: TimeInterval
    private let body: Body

    public init(minimumInterval: TimeInterval, body: @escaping Body) {
        self.minimumInterval = minimumInterval
        self.body = body
    }

    public func submit(_ value: Double) {
        target = value
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    private func drain() async {
        while let value = target {
            target = nil
            await body(value)
            if target != nil {
                try? await Task.sleep(nanoseconds: UInt64(minimumInterval * 1_000_000_000))
            }
        }
        running = false
    }
}
