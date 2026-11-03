import Foundation
import Darwin

enum ServicePaths {
    static let root = "/Library/Application Support/DriveThermalService"
    static let state = root + "/state"
    static let socket = root + "/control.sock"
    static let label = "local.drivethermal.service"
    static let plist = "/Library/LaunchDaemons/" + label + ".plist"
}
struct CaptureSettings: Codable, Equatable {
    static let minimumMinutes = 5
    static let maximumMinutes = 1440
    static let presets = [15, 30, 60, 180, 360]
    var automatic = false
    var intervalMinutes = 180
    var valid: Bool { (Self.minimumMinutes...Self.maximumMinutes).contains(intervalMinutes) }
    func forScheduling(volumePaused: Bool) -> CaptureSettings {
        CaptureSettings(automatic: automatic && !volumePaused, intervalMinutes: intervalMinutes)
    }
}
struct ServiceRequest: Codable {
    var command: String
    var settings: CaptureSettings? = nil
}
struct ServiceStatus: Codable {
    var version = "2"
    var volumePaused: Bool? = nil
    var settings = CaptureSettings()
    var busy = false
    var nextAttempt: Date? = nil
    var lastAttempt: Date? = nil
    var result = "ready"
    var readings: [Reading] = []
    var error: String? = nil
    var log: String? = nil
}
// All scheduling uses elapsed wakeful ticks; do not replay missed intervals after sleep.
struct CaptureSchedule {
    var next: Date?
    var lastTick: Date?
    mutating func reset(_ settings: CaptureSettings, now: Date) {
        next = settings.automatic ? now.addingTimeInterval(Double(settings.intervalMinutes * 60)) : nil
        lastTick = now
    }
    mutating func due(_ settings: CaptureSettings, now: Date, busy: Bool) -> Bool {
        guard settings.valid && settings.automatic else { next = nil; lastTick = now; return false }
        if let lastTick, now.timeIntervalSince(lastTick) > 90 || now < lastTick {
            reset(settings, now: now); return false
        }
        lastTick = now
        guard let next else { reset(settings, now: now); return false }
        guard now >= next else { return false }
        self.next = now.addingTimeInterval(Double(settings.intervalMinutes * 60))
        return !busy
    }
}
enum ServiceIO {
    static func address() -> sockaddr_un {
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(ServicePaths.socket.utf8) + [0]
        precondition(bytes.count < MemoryLayout.size(ofValue: addr.sun_path))
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
    static func prepare(_ fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    static func readLine(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let n = Darwin.read(fd, &buffer, min(buffer.count, limit - data.count))
            guard n > 0 else { throw NSError(domain: "ServiceRead", code: 1) }
            if let end = buffer[..<n].firstIndex(of: 10) { data.append(contentsOf: buffer[..<end]); return data }
            data.append(contentsOf: buffer[..<n])
        }
        throw NSError(domain: "ServiceSize", code: 1)
    }
    static func writeLine(_ fd: Int32, data: Data) throws {
        var bytes = data; bytes.append(10)
        try bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard n > 0 else { throw NSError(domain: "ServiceWrite", code: 1) }; sent += n
            }
        }
    }
    static func request(_ request: ServiceRequest) throws -> ServiceStatus {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "ServiceSocket", code: 1) }
        defer { close(fd) }; prepare(fd)
        var addr = address()
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw NSError(domain: "ServiceUnavailable", code: Int(errno)) }
        var uid: uid_t = 1; var gid: gid_t = 1
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw NSError(domain: "ServiceIdentity", code: 1) }
        try writeLine(fd, data: JSONEncoder().encode(request))
        return try JSONDecoder().decode(ServiceStatus.self, from: readLine(fd, limit: 2_000_000))
    }
}
