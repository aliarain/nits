import Foundation

/// A one-line client for the running app's control socket. Commands that only make sense
/// inside the app (keep awake, preset application, live UI refresh) go through here; all
/// hardware control still works directly when the app is not running.
public enum ControlClient {
    public static func isAppRunning() -> Bool {
        send("ping", timeout: 0.5) == "ok"
    }

    public static func send(_ command: String, timeout: TimeInterval = 2.0) -> String? {
        let path = NitsPaths.controlSocket.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                _ = strncpy(destination, path, 103)
            }
        }

        var timeval = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, size)
            }
        }
        guard connected == 0 else { return nil }

        let payload = Array((command + "\n").utf8)
        _ = payload.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            response.append(buffer, count: count)
            if response.contains(0x0A) { break }
        }
        return String(data: response, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
