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
