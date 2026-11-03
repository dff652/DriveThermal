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
                       hours: integer("Power On Hours"), errors: first("Media/Data Integrity Errors").flatMap(UInt64.init))
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
    static func parse(_ data: Data, expected: Enrollment) -> MountState {
        guard let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              (p["VolumeUUID"] as? String)?.lowercased() == expected.uuid.lowercased() else {
            return MountState(connected: false, mounted: false)
        }
        return MountState(connected: true, mounted: p["MountPoint"] as? String == expected.mountPath,
                          freeBytes: (p["APFSContainerFree"] as? NSNumber)?.int64Value)
    }
}
