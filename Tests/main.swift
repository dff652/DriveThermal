import Foundation
func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
let sample = """
Model: TEST SSD
Critical Warning: 0x00 (none)
Composite Temperature: 44 C
Available Spare: 100%
Percentage Used: 0%
Power On Hours: 490
Media/Data Integrity Errors: 0
probe result: identify=OK smart=OK error_log=OK
"""
let date = Date(timeIntervalSince1970: 100)
let good = Reading.parse(summary: sample, id: "test", date: date)
check(good?.celsius == 44 && good?.hours == 490 && good?.capturedAt == date, "valid result")
check(Reading.parse(summary: sample.replacingOccurrences(of: "smart=OK", with: "smart=FAILED"), id: "bad", date: date) == nil, "failed capture accepted")
check(Reading.parse(summary: sample.replacingOccurrences(of: "44 C", with: "-273 C"), id: "bad", date: date) == nil, "invalid sensor accepted")
check(Reading.parse(summary: sample.replacingOccurrences(of: "44 C", with: "nan C"), id: "bad", date: date) == nil, "nan accepted")
check(Reading.parse(summary: sample.replacingOccurrences(of: "0x00 (none)", with: "0x02"), id: "warning", date: date)?.warning == 2, "warning lost")
let roundtrip = try JSONDecoder().decode(Reading.self, from: JSONEncoder().encode(good!))
check(roundtrip == good!, "history roundtrip failed")
print("Health parser: 6 checks passed")
let privateReading = Reading(id: "PRIVATE-ID", capturedAt: date, celsius: 44, model: "PRIVATE-MODEL-SERIAL", warning: 0, spare: 100, used: 0, hours: 999999, errors: 0)
let info = BuildInfo(version: "0.2.0", build: "2", revision: "test", builtAt: "test", bundledCollector: false)
let report = DiagnosticReport.make(build: info, os: "test", mounted: true, enrolled: true, collectorAvailable: false, busy: false, reading: privateReading, events: [EventRecord(date: date, event: .captureFailed, exitCode: 1)])
check(!report.contains("PRIVATE-") && !report.contains("999999"), "private hardware fields leaked")
check(report.contains("0.2.0 (2)") && report.contains("captureFailed exit=1"), "diagnostic metadata missing")
let malicious = Data("{\"date\":0,\"event\":\"SERIAL-SECRET\",\"exitCode\":0}".utf8)
check((try? JSONDecoder().decode(EventRecord.self, from: malicious)) == nil, "unknown log content accepted")
print("Diagnostics privacy: 3 checks passed")

let extended = sample + """

Firmware: DEMO1
Available Spare Threshold: 10%
Data Units Read (x512,000B): 1000000
Data Units Written (x512,000B): 2000000
Host Read Commands: 18446744073709551616
Power Cycles: 12
Unsafe Shutdowns: 3
Error Info Log Entries: 0
"""
let rich = Reading.parse(summary: extended, id: "rich", date: date)!
check(rich.smart?.firmware == "DEMO1" && rich.smart?.unsafeShutdowns == "3", "extended SMART fields missing")
check(rich.smart?.readCommands == "18446744073709551616", "128-bit counter truncated")
check(SMARTDetails.dataAmount(rich.smart?.dataRead) == "512.00 GB" && SMARTDetails.dataAmount(rich.smart?.dataWritten) == "1.02 TB", "data unit conversion incorrect")
check(SMARTDetails(fields: ["Power Cycles": "-4", "Unsafe Shutdowns": "nan"]).powerCycles == nil, "invalid counter accepted")
var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good!)) as! [String: Any]
legacy.removeValue(forKey: "smart")
let old = try JSONDecoder().decode(Reading.self, from: JSONSerialization.data(withJSONObject: legacy))
check(old.smart == nil && old.celsius == 44, "old history incompatible")
let enrichedReport = DiagnosticReport.make(build: info, os: "test", mounted: true, enrolled: true, collectorAvailable: true, busy: false, reading: rich, events: [])
check(!enrichedReport.contains("DEMO1") && !enrichedReport.contains("18446744073709551616"), "expanded SMART fields leaked into diagnostics")
let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let profile = temp.appendingPathComponent("device.plist")
let uuid = "11111111-1111-4111-8111-111111111111"
try PropertyListSerialization.data(fromPropertyList: ["volume_uuid": uuid, "mount_path": "/Volumes/Test", "nvme_model": "TEST SSD"], format: .xml, options: 0).write(to: profile)
let enrollment = Enrollment(url: profile)!
func mountData(_ fields: [String: Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0) }
var fields: [String: Any] = ["VolumeUUID": uuid, "MountPoint": "/Volumes/Test", "APFSContainerSize": 1000000000, "APFSContainerFree": 400000000, "VolumeSize": 0, "FreeSpace": 0]
let capacity = MountState.parse(try mountData(fields), expected: enrollment)
check(capacity.mounted && capacity.isAPFS && capacity.totalBytes == 1000000000 && capacity.freeBytes == 400000000, "APFS shared space incorrect")
fields["VolumeUUID"] = "22222222-2222-4222-8222-222222222222"
check(!MountState.parse(try mountData(fields), expected: enrollment).connected, "wrong-volume capacity accepted")
fields["VolumeUUID"] = uuid; fields["APFSContainerFree"] = 2000000000
check(MountState.parse(try mountData(fields), expected: enrollment).freeBytes == nil, "impossible capacity accepted")
print("SMART expansion, history migration, privacy and capacity: 9 checks passed")

let emptySeries = TemperatureSeries(readings: [])
check(emptySeries.values.isEmpty && emptySeries.temperatureRange.lowerBound < emptySeries.temperatureRange.upperBound, "empty chart invalid")
let singleSeries = TemperatureSeries(readings: [good!])
check(singleSeries.timeRange.contains(date) && singleSeries.timeRange.lowerBound < date && singleSeries.timeRange.upperBound > date, "singleton chart has no time range")
var later = good!; later.id = "later"; later.capturedAt = date.addingTimeInterval(3600)
let flatSeries = TemperatureSeries(readings: [later, good!])
check(flatSeries.values.map(\.id) == [good!.id, "later"] && flatSeries.temperatureRange == 41...47 && flatSeries.values.last!.capturedAt.timeIntervalSince(flatSeries.values.first!.capturedAt) == 3600, "constant or irregular-time chart altered samples")
let many = (0..<40).map { i -> Reading in var r = good!; r.id = String(i); r.capturedAt = date.addingTimeInterval(Double(i * i)); return r }
let recentSeries = TemperatureSeries(readings: many.reversed())
check(recentSeries.values.count == 30 && recentSeries.values.first?.id == "10" && recentSeries.values.last?.id == "39", "chart does not show latest 30 points")
print("Temperature chart domains: 4 checks passed")

var scheduleTest = CaptureSchedule()
let autoSettings = CaptureSettings(automatic: true, intervalMinutes: 30)
let start = Date(timeIntervalSince1970: 1000)
scheduleTest.reset(autoSettings, now: start)
check(scheduleTest.next == start.addingTimeInterval(1800), "interval incorrect")
for offset in stride(from: 15, to: 1800, by: 15) {
    check(!scheduleTest.due(autoSettings, now: start.addingTimeInterval(Double(offset)), busy: false), "timer fired early")
}
check(scheduleTest.due(autoSettings, now: start.addingTimeInterval(1800), busy: false), "timer did not fire")
check(!scheduleTest.due(autoSettings, now: start.addingTimeInterval(7200), busy: false), "sleep caused catch-up capture")
check(scheduleTest.next == start.addingTimeInterval(9000), "wake interval not reset")
scheduleTest.reset(CaptureSettings(), now: start)
check(scheduleTest.next == nil && !scheduleTest.due(CaptureSettings(), now: start.addingTimeInterval(99999), busy: false), "manual mode scheduled capture")
check(!CaptureSettings(automatic: true, intervalMinutes: 0).valid && !CaptureSettings(automatic: true, intervalMinutes: 1441).valid, "invalid interval accepted")
scheduleTest.reset(autoSettings, now: start)
scheduleTest.lastTick = start.addingTimeInterval(1790)
check(!scheduleTest.due(autoSettings, now: start.addingTimeInterval(1800), busy: true) && scheduleTest.next == start.addingTimeInterval(3600), "overlapping or backlog capture")
print("Background schedule: 7 checks passed")

let paused = autoSettings.forScheduling(volumePaused: true)
scheduleTest.reset(paused, now: start)
check(!paused.automatic && paused.intervalMinutes == 30 && scheduleTest.next == nil, "unmounted disk still scheduled")
scheduleTest.reset(autoSettings.forScheduling(volumePaused: false), now: start)
check(scheduleTest.next == start.addingTimeInterval(1800), "mount did not restart original interval")
check(!CaptureSettings().forScheduling(volumePaused: false).automatic, "mount enabled automatic mode for manual user")
let oldService = Data("{\"version\":\"1\",\"settings\":{\"automatic\":true,\"intervalMinutes\":180},\"busy\":false,\"result\":\"ready\",\"readings\":[]}".utf8)
let oldStatus = try JSONDecoder().decode(ServiceStatus.self, from: oldService)
check(oldStatus.volumePaused == nil && oldStatus.version == "1", "old service compatibility lost")
fields["VolumeUUID"] = uuid
fields.removeValue(forKey: "MountPoint")
let unmountedState = MountState.parse(try mountData(fields), expected: enrollment)
check(unmountedState.connected && !unmountedState.mounted, "unmounted volume incorrectly shown as disconnected")
print("Volume pause, resume, manual mode and compatibility: 5 checks passed")
