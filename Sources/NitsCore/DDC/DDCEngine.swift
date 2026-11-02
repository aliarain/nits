import Foundation
import CoreGraphics

public struct DDCProbe: Sendable {
    public let value: DDCValue?
    public let reply: [UInt8]
    public let milliseconds: Double
    public let failure: String?

    public init(value: DDCValue?, reply: [UInt8], milliseconds: Double, failure: String?) {
        self.value = value
        self.reply = reply
        self.milliseconds = milliseconds
        self.failure = failure
    }
}

/// Robust DDC/CI access.
///
/// Stability rules encoded here, learned from real monitors:
///  - one serial queue per display, so a wedged channel cannot stall the others;
///  - every reply validated by header AND checksum, because ACKs lie;
///  - a 5 s value cache so a slider does not hammer a fragile controller;
///  - read quarantine after repeated failures (fresh probe window after expiry);
///  - a failed read slower than 3 s quarantines immediately (a deaf channel costs ~6 s);
///  - the whole channel map is flushed on any display reconfiguration, because macOS
///    reshuffles display IDs without a removal event;
///  - `hold()` parks all DDC traffic around display enable/disable.
public final class DDCEngine: @unchecked Sendable {
    public static let brightnessVCP: UInt8 = 0x10
    public static let contrastVCP: UInt8 = 0x12
    public static let redGainVCP: UInt8 = 0x16
    public static let greenGainVCP: UInt8 = 0x18
    public static let blueGainVCP: UInt8 = 0x1A
    public static let inputVCP: UInt8 = 0x60
    public static let volumeVCP: UInt8 = 0x62
    public static let powerVCP: UInt8 = 0xD6
    public static let audioMuteVCP: UInt8 = 0x8D

    public static let commonVCPCodes: [UInt8] = [
        0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x60, 0x62, 0x6C, 0x87, 0x8D, 0xD6, 0xDC,
    ]

    private struct CacheEntry {
        let value: DDCValue
        let timestamp: Date

        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > 5.0
        }
    }

    private struct Quarantine {
        var failures: Int
        var until: Date?
    }

    private let queues = DDCOperationQueuePool()
    private let provider: DDCChannelProviding

    private let cacheLock = NSLock()
    private var valueCache: [UInt32: [UInt8: CacheEntry]] = [:]
    private var readState: [UInt32: Quarantine] = [:]
    private var capabilityCache: [String: (value: DDCCapabilities, timestamp: Date)] = [:]

    private let readQuarantineThreshold = 6
    private let readQuarantineSeconds: TimeInterval = 600
    private let deafAttemptMilliseconds = 3000.0
    private let slowOperationMilliseconds = 500.0

    public init(provider: DDCChannelProviding = DefaultDDCChannelProvider()) {
        self.provider = provider
    }

    // MARK: - Public API

    public func write(
        display: DisplaySnapshot,
        code: UInt8,
        value: UInt16,
        retries: Int = 3
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            queues.queue(for: display.id).async {
                let attempted = max(1, retries)
                var succeeded = false
                for attempt in 0..<attempted {
                    let start = DispatchTime.now()
                    if let channel = self.provider.channel(for: display),
                       channel.write(code: code, value: value) {
                        succeeded = true
                        self.logSlow("write \(Self.hex(code))=\(value)", display: display, started: start)
                        break
                    }
                    self.logSlow("failed write \(Self.hex(code))=\(value) attempt \(attempt + 1)", display: display, started: start)
                    if attempt < attempted - 1 {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
                if succeeded {
                    self.cacheLock.lock()
                    self.valueCache[display.id]?[code] = nil
                    self.cacheLock.unlock()
                }
                continuation.resume(returning: succeeded)
            }
        }
    }

    public func read(
        display: DisplaySnapshot,
        code: UInt8,
        useCache: Bool = true
    ) async -> DDCValue? {
        if useCache {
            let cached: DDCValue? = cacheLock.withLock {
                guard let entry = valueCache[display.id]?[code], !entry.isExpired else {
                    return nil
                }
                return entry.value
            }
            if let cached { return cached }
        }

        return await withCheckedContinuation { continuation in
            queues.queue(for: display.id).async {
                let result = self.readSynchronous(display: display, code: code)
                if let result, let value = result.value {
                    self.cacheLock.lock()
                    var entries = self.valueCache[display.id] ?? [:]
                    entries[code] = CacheEntry(value: value, timestamp: Date())
                    self.valueCache[display.id] = entries
                    self.cacheLock.unlock()
                }
                continuation.resume(returning: result?.value)
            }
        }
    }

    /// Raw reply plus timing, for the diagnostics report.
    public func probe(display: DisplaySnapshot, code: UInt8) async -> DDCProbe {
        await withCheckedContinuation { continuation in
            queues.queue(for: display.id).async {
                let start = DispatchTime.now()
                guard let channel = self.provider.channel(for: display) else {
                    continuation.resume(returning: DDCProbe(
                        value: nil, reply: [], milliseconds: 0, failure: "no DDC channel"
                    ))
                    return
                }
                guard let reply = channel.readRaw(code: code) else {
                    let ms = Self.milliseconds(since: start)
                    continuation.resume(returning: DDCProbe(
                        value: nil, reply: [], milliseconds: ms, failure: "I2C read failed"
                    ))
                    return
                }
                let ms = Self.milliseconds(since: start)
                let value = DDCPacket.parseGetReply(
                    reply,
                    expecting: code,
                    allowZeroMax: code == Self.inputVCP
                )
                continuation.resume(returning: DDCProbe(
                    value: value,
                    reply: reply,
                    milliseconds: ms,
                    failure: value == nil ? "reply rejected (header/checksum/max)" : nil
                ))
            }
        }
    }

    public func capabilities(display: DisplaySnapshot, maxAge: TimeInterval = 600) async -> DDCCapabilities? {
        let cached: DDCCapabilities? = cacheLock.withLock {
            guard let entry = capabilityCache[display.uuid],
                  Date().timeIntervalSince(entry.timestamp) < maxAge
            else { return nil }
            return entry.value
        }
        if let cached { return cached }

        let raw = await readCapabilitiesString(display: display)
        guard let raw, !raw.isEmpty else { return nil }
        let parsed = DDCCapabilities.parse(raw)
        cacheLock.withLock {
            capabilityCache[display.uuid] = (parsed, Date())
        }
        return parsed
    }

    public func invalidateAll() {
        NitsLog.ddc.notice("display reconfiguration: DDC channel map flushed")
        provider.invalidate()
        cacheLock.lock()
        valueCache.removeAll()
        readState.removeAll()
        capabilityCache.removeAll()
        cacheLock.unlock()
    }

    public func invalidate(displayID: UInt32) {
        provider.invalidate()
        cacheLock.lock()
        valueCache.removeValue(forKey: displayID)
        readState.removeValue(forKey: displayID)
        cacheLock.unlock()
    }

    /// Parks DDC until the returned closure runs. Use around any display enable/disable.
    public func hold() async -> @Sendable () -> Void {
        let idle = DispatchSemaphore(value: 0)
        let release = queues.hold(timeout: 15) { idle.signal() }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                idle.wait()
                continuation.resume()
            }
        }
        return release
    }

    public func readsQuarantined(displayID: UInt32) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let state = readState[displayID], let until = state.until else { return false }
        return Date() < until
    }

    // MARK: - Synchronous work (already on the display's queue)

    private func readSynchronous(display: DisplaySnapshot, code: UInt8) -> (value: DDCValue?, ms: Double)? {
        if readsQuarantineActive(displayID: display.id) {
            return nil
        }

        guard let channel = provider.channel(for: display) else { return nil }

        let start = DispatchTime.now()
        let reply = channel.readRaw(code: code)
        let ms = Self.milliseconds(since: start)

        var value: DDCValue?
        if let reply {
            value = DDCPacket.parseGetReply(
                reply,
                expecting: code,
                allowZeroMax: code == Self.inputVCP || code == Self.audioMuteVCP
            )
        }

        cacheLock.lock()
        var state = readState[display.id] ?? Quarantine(failures: 0, until: nil)
        if value == nil {
            state.failures += 1
            if ms >= deafAttemptMilliseconds {
                state.failures = max(state.failures, readQuarantineThreshold)
            }
            if state.failures >= readQuarantineThreshold {
                state.until = Date().addingTimeInterval(readQuarantineSeconds)
                NitsLog.ddc.notice("display \(display.id, privacy: .public): reads quarantined for \(Int(self.readQuarantineSeconds), privacy: .public) s after \(state.failures, privacy: .public) failures")
            }
        } else {
            state.failures = 0
            state.until = nil
        }
        readState[display.id] = state
        cacheLock.unlock()

        if ms > slowOperationMilliseconds {
            NitsLog.ddc.notice("slow DDC read \(Self.hex(code), privacy: .public) display \(display.id, privacy: .public): \(Int(ms), privacy: .public) ms")
        }
        if let value {
            NitsLog.ddc.debug("read \(Self.hex(code), privacy: .public) display \(display.id, privacy: .public): \(value.current, privacy: .public)/\(value.max, privacy: .public)")
        }
        return (value, ms)
    }

    private func readsQuarantineActive(displayID: UInt32) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let state = readState[displayID], let until = state.until else { return false }
        if Date() >= until {
            readState[displayID] = Quarantine(failures: 0, until: nil)
            NitsLog.ddc.notice("display \(displayID, privacy: .public): read quarantine expired, probing again")
            return false
        }
        return true
    }

    private func readCapabilitiesString(display: DisplaySnapshot) async -> String? {
        await withCheckedContinuation { continuation in
            queues.queue(for: display.id).async {
                guard let channel = self.provider.channel(for: display) else {
                    continuation.resume(returning: nil)
                    return
                }

                var bytes: [UInt8] = []
                var badReplies = 0
                var consecutiveBad = 0
                var offset = 0

                // A stubborn monitor can answer every chunk with a null frame. Cap both
                // the total and the consecutive failures so this never parks the display's
                // DDC queue for tens of seconds (the queue also delays disconnect holds).
                while bytes.count < 4096 {
                    if self.readsQuarantineActive(displayID: display.id) {
                        continuation.resume(returning: nil)
                        return
                    }
                    guard let reply = channel.readCapabilitiesRaw(offset: offset) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    guard let chunk = DDCCapabilitiesCodec.data(fromReply: reply, offset: offset) else {
                        badReplies += 1
                        consecutiveBad += 1
                        if badReplies >= 64 || consecutiveBad >= 12 {
                            NitsLog.ddc.notice("capabilities display \(display.id, privacy: .public): gave up after \(badReplies, privacy: .public) bad replies")
                            continuation.resume(returning: nil)
                            return
                        }
                        continue
                    }
                    consecutiveBad = 0
                    if chunk.isEmpty {
                        let text = String(bytes: bytes.filter { $0 != 0 }, encoding: .isoLatin1)
                        NitsLog.ddc.notice("capabilities display \(display.id, privacy: .public): \(bytes.count, privacy: .public) bytes, \(badReplies, privacy: .public) bad replies")
                        continuation.resume(returning: text)
                        return
                    }
                    bytes.append(contentsOf: chunk)
                    offset = bytes.count
                }
                continuation.resume(returning: String(bytes: bytes.filter { $0 != 0 }, encoding: .isoLatin1))
            }
        }
    }

    // MARK: - Helpers

    private static func hex(_ code: UInt8) -> String {
        String(format: "0x%02X", code)
    }

    private static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private func logSlow(_ action: String, display: DisplaySnapshot, started: DispatchTime) {
        let ms = Self.milliseconds(since: started)
        if ms > slowOperationMilliseconds {
            NitsLog.ddc.notice("slow \(action, privacy: .public) display \(display.id, privacy: .public): \(Int(ms), privacy: .public) ms")
        }
    }
}
