import Foundation

struct Reading: Codable, Identifiable, Equatable {
    var id: String
    var capturedAt: Date
    var celsius: Double
    var model: String
    var warning: Int
    var spare: Int?
    var used: Int?
    var hours: Int?
    var errors: UInt64?
    var smart: SMARTDetails? = nil

    static func parse(summary: String, id: String, date: Date) -> Reading? {
        // Partial or failed transport output must never become a valid reading.
        guard summary.contains("probe result: identify=OK smart=OK error_log=OK") else { return nil }
        var fields = [String: String]()
        for line in summary.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        func first(_ key: String) -> String? { fields[key]?.split(separator: " ").first.map(String.init) }
        func integer(_ key: String) -> Int? { first(key).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
        guard let t = first("Composite Temperature").flatMap(Double.init), t.isFinite, (-40...150).contains(t),
              let w = first("Critical Warning"), w.hasPrefix("0x"), let warning = Int(w.dropFirst(2), radix: 16),
              let model = fields["Model"], !model.isEmpty else { return nil }
        return Reading(id: id, capturedAt: date, celsius: t, model: model, warning: warning,
                       spare: integer("Available Spare"), used: integer("Percentage Used"),
                       hours: integer("Power On Hours"), errors: first("Media/Data Integrity Errors").flatMap(UInt64.init),
                       smart: SMARTDetails(fields: fields))
    }
}

// Keep the NVMe 128-bit counters as decimal strings, without narrowing to UInt64.
struct SMARTDetails: Codable, Equatable {
    var firmware: String?
    var spareThreshold: String?
    var dataRead: String?
    var dataWritten: String?
    var readCommands: String?
    var writeCommands: String?
    var busyMinutes: String?
    var powerCycles: String?
    var unsafeShutdowns: String?
    var errorLogEntries: String?
    init(fields: [String: String]) {
        func counter(_ key: String) -> String? {
            guard let value = fields[key], !value.isEmpty,
                  value.utf8.allSatisfy({ (48...57).contains($0) }), value.count <= 39,
                  let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
                  !decimal.isNaN else { return nil }
            return value
        }
        firmware = fields["Firmware"]
        spareThreshold = fields["Available Spare Threshold"]
        dataRead = counter("Data Units Read (x512,000B)")
        dataWritten = counter("Data Units Written (x512,000B)")
        readCommands = counter("Host Read Commands")
        writeCommands = counter("Host Write Commands")
        busyMinutes = counter("Controller Busy Time (min)")
        powerCycles = counter("Power Cycles")
        unsafeShutdowns = counter("Unsafe Shutdowns")
        errorLogEntries = counter("Error Info Log Entries")
    }
    static func dataAmount(_ units: String?) -> String {
        guard let units, let value = Decimal(string: units, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return "—" }
        let gb = NSDecimalNumber(decimal: value * 512000 / 1000000000).doubleValue
        return gb >= 1000 ? String(format: "%.2f TB", gb / 1000) : String(format: "%.2f GB", gb)
    }
}

struct Enrollment {
    let uuid: String
    let mountPath: String
    let name: String
    let model: String
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let uuid = p["volume_uuid"] as? String, UUID(uuidString: uuid) != nil,
              let mount = p["mount_path"] as? String, mount.hasPrefix("/Volumes/"),
              let model = p["nvme_model"] as? String else { return nil }
        self.uuid = uuid; self.mountPath = mount; self.name = URL(fileURLWithPath: mount).lastPathComponent; self.model = model
    }
}

struct MountState {
    var connected: Bool
    var mounted: Bool
    var freeBytes: Int64?
    var totalBytes: Int64?
    var isAPFS = false
    static func capacity(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "—" }
        return String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }
    static func parse(_ data: Data, expected: Enrollment) -> MountState {
        guard let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              (p["VolumeUUID"] as? String)?.lowercased() == expected.uuid.lowercased() else {
            return MountState(connected: false, mounted: false)
        }
        let apfs = p["APFSContainerSize"] != nil
        let total = (p[apfs ? "APFSContainerSize" : "TotalSize"] as? NSNumber)?.int64Value
        let free = (p[apfs ? "APFSContainerFree" : "VolumeFreeSpace"] as? NSNumber)?.int64Value
        return MountState(connected: true, mounted: p["MountPoint"] as? String == expected.mountPath,
                          freeBytes: free.flatMap { $0 >= 0 && $0 <= (total ?? Int64.max) ? $0 : nil },
                          totalBytes: total.flatMap { $0 > 0 ? $0 : nil }, isAPFS: apfs)
    }
}

// Axes use actual capture dates; no fabricated samples or extrapolation to now.
struct TemperatureSeries {
    let values: [Reading]
    let timeRange: ClosedRange<Date>
    let temperatureRange: ClosedRange<Double>
    let spansDays: Bool
    init(readings: [Reading]) {
        values = Array(readings.filter { $0.celsius.isFinite && (-40...150).contains($0.celsius) && $0.capturedAt.timeIntervalSinceReferenceDate.isFinite }
            .sorted { $0.capturedAt < $1.capturedAt }.suffix(30))
        let first = values.first?.capturedAt ?? Date(timeIntervalSince1970: 0)
        let last = values.last?.capturedAt ?? first
        let padding = max(60, last.timeIntervalSince(first) * 0.08)
        timeRange = first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
        let low = values.map(\.celsius).min() ?? 40
        let high = values.map(\.celsius).max() ?? 40
        temperatureRange = floor(low - 3)...ceil(high + 3)
        spansDays = !Calendar.current.isDate(first, inSameDayAs: last)
    }
}
