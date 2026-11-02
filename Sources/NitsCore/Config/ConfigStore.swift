import Foundation

/// JSON config in Application Support. Writes are atomic (temp file + rename), a corrupt
/// file is preserved as `.corrupt-<timestamp>` instead of silently discarded, and the
/// app and CLI can both use it safely at the file level.
public final class ConfigStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var value: NitsConfig
    private var revisionAtLoad: Int
    private var unsaved = false

    public init(url: URL = NitsPaths.configFile) {
        self.url = url
        NitsPaths.ensureApplicationSupport()
        let loaded = Self.load(from: url)
        value = loaded
        revisionAtLoad = loaded.revision
    }

    public func snapshot() -> NitsConfig {
        lock.withLock { value }
    }

    /// True while in-memory mutations (e.g. a slider drag) have not been written yet.
    public var hasUnsavedChanges: Bool {
        lock.withLock { unsaved }
    }

    /// Applies a mutation. `persist == false` leaves the write to the caller's debounce.
    public func update(persist: Bool = true, _ mutate: (inout NitsConfig) -> Void) {
        lock.lock()
        var copy = value
        mutate(&copy)
        copy.revision += 1
        value = copy
        revisionAtLoad = copy.revision
        unsaved = true
        lock.unlock()
        if persist { save() }
    }

    /// Re-reads the file if another process wrote it. Local unsaved changes win: a reload
    /// would discard a brightness drag that has not hit disk yet.
    @discardableResult
    public func reloadIfChanged() -> Bool {
        lock.lock()
        let dirty = unsaved
        lock.unlock()
        guard !dirty else { return false }

        let disk = Self.load(from: url)
        lock.lock()
        defer { lock.unlock() }
        guard disk.revision != revisionAtLoad else { return false }
        value = disk
        revisionAtLoad = disk.revision
        return true
    }

    public func save() {
        let snapshot = lock.withLock { value }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".config-\(UUID().uuidString).json")
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            lock.withLock { unsaved = false }
        } catch {
            NitsLog.config.error("could not save config: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from url: URL) -> NitsConfig {
        guard let data = try? Data(contentsOf: url) else { return NitsConfig() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(NitsConfig.self, from: data)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("config.corrupt-\(stamp).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            NitsLog.config.error("config unreadable; preserved at \(backup.lastPathComponent, privacy: .public)")
            return NitsConfig()
        }
    }
}
