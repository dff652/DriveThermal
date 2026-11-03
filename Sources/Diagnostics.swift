import Foundation

struct BuildInfo {
    let version: String
    let build: String
    let revision: String
    let builtAt: String
    let bundledCollector: Bool
    static let current = BuildInfo(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
        revision: Bundle.main.object(forInfoDictionaryKey: "DTBuildRevision") as? String ?? "uncommitted",
        builtAt: Bundle.main.object(forInfoDictionaryKey: "DTBuildDate") as? String ?? "unknown",
        bundledCollector: Bundle.main.object(forInfoDictionaryKey: "DTBundledCollector") as? Bool ?? false)
    var label: String { "\(version) (\(build))" }
    static let maintainerURL = URL(string: "https://github.com/dff652")!
    static let repositoryURL = URL(string: "https://github.com/dff652/DriveThermal")!
}

enum DiagnosticEvent: String, Codable {
    case appStarted, captureRequested, captureSucceeded, captureFailed, captureLaunchFailed
    case historyImported, diagnosticExported
}
struct EventRecord: Codable {
    let date: Date
    let event: DiagnosticEvent
    let exitCode: Int32?
}

final class EventLog {
    let directory: URL
    let file: URL
    init(directory: URL) { self.directory = directory; self.file = directory.appendingPathComponent("events.jsonl") }
    // Only enumerated events and numeric codes are accepted, never free-form process output.
    func record(_ event: DiagnosticEvent, exitCode: Int32? = nil) {
        do {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 262144 {
                let previous = directory.appendingPathComponent("events.previous.jsonl")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: file, to: previous)
            }
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            var data = try JSONEncoder().encode(EventRecord(date: Date(), event: event, exitCode: exitCode))
            data.append(10); try handle.write(contentsOf: data)
        } catch { /* Logging failure must not interrupt disk recovery. */ }
    }
    func recent() -> [EventRecord] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(100).compactMap {
            try? JSONDecoder().decode(EventRecord.self, from: Data($0.utf8))
        }
    }
}

struct DiagnosticReport {
    // Deliberately does not accept Enrollment, raw logs, file paths, serials or UUIDs.
    static func make(build: BuildInfo, os: String, mounted: Bool, enrolled: Bool,
                     collectorAvailable: Bool, busy: Bool, reading: Reading?, events: [EventRecord]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["DriveThermal diagnostic report (allowlisted fields)",
                     "App: \(build.label)", "Revision: \(build.revision)", "Build UTC: \(build.builtAt)",
                     "macOS: \(os)", "Collector bundled: \(build.bundledCollector)",
                     "Collector available: \(collectorAvailable)", "Enrolled: \(enrolled)",
                     "Mounted: \(mounted)", "Capture in progress: \(busy)",
                     "Temperature mode: manual snapshot"]
        if let r = reading {
            lines += ["Last capture UTC: \(iso.string(from: r.capturedAt))", "Last temperature C: \(r.celsius)",
                      "Last critical warning: \(r.warning)"]
        }
        lines += ["", "Recent application events (not raw collector logs):"]
        for e in events {
            lines.append("\(iso.string(from: e.date)) \(e.event.rawValue) exit=\(e.exitCode.map(String.init) ?? "-")")
        }
        lines += ["", "Excluded: hardware serials, UUIDs, volume names, model names, user paths, raw SMART pages and raw logs."]
        return lines.joined(separator: "\n") + "\n"
    }
}
