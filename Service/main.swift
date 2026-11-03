import Foundation
import Darwin

let fm = FileManager.default
let stateURL = URL(fileURLWithPath: ServicePaths.state)
func privateFile(_ name: String) -> URL { stateURL.appendingPathComponent(name) }
func save<T: Encodable>(_ value: T, _ name: String) throws {
    try JSONEncoder().encode(value).write(to: privateFile(name), options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateFile(name).path)
}
func rootOwned(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0 && st.st_uid == 0 && st.st_mode & 0o022 == 0 && st.st_mode & S_IFMT != S_IFLNK
}
guard geteuid() == 0, rootOwned(ServicePaths.root), rootOwned(ServicePaths.state),
      rootOwned(ServicePaths.root + "/collector/rtl9210-health"),
      let ownerData = fm.contents(atPath: ServicePaths.root + "/owner.json"),
      let owner = try? JSONDecoder().decode(UInt32.self, from: ownerData), owner >= 501 else { exit(78) }
umask(0o077)
let queue = DispatchQueue(label: "DriveThermalService.state")
var status = ServiceStatus()
if let data = try? Data(contentsOf: privateFile("settings.json")),
   let settings = try? JSONDecoder().decode(CaptureSettings.self, from: data), settings.valid { status.settings = settings }
if let data = try? Data(contentsOf: privateFile("history.json")),
   let readings = try? JSONDecoder().decode([Reading].self, from: data) { status.readings = readings }
status.volumePaused = (try? Data(contentsOf: privateFile("volume-paused.json"))).flatMap { try? JSONDecoder().decode(Bool.self, from: $0) } ?? false
func scheduledSettings() -> CaptureSettings { status.settings.forScheduling(volumePaused: status.volumePaused == true) }
var schedule = CaptureSchedule()
// An interrupted previous capture requires an operator to inspect recovery; never loop on it.
if fm.fileExists(atPath: privateFile("capture-in-progress").path) {
    status.settings.automatic = false; status.result = "interrupted"; try? save(status.settings, "settings.json")
}
schedule.reset(scheduledSettings(), now: Date())
var process: Process?
var lastManual: Date?
let captureLock = open(privateFile("capture.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
guard captureLock >= 0 else { exit(73) }

func beginCapture(operation: String = "capture") {
    let isCapture = operation == "capture"
    guard !status.busy else { return }
    // USB interfaces need the enrolled user's console audit session as well as
    // root device-capture authority. Never inherit a different user's session.
    var console = stat()
    guard stat("/dev/console", &console) == 0, console.st_uid == owner else {
        status.result = "skippedSession"; schedule.reset(scheduledSettings(), now: Date()); return
    }
    guard flock(captureLock, LOCK_EX | LOCK_NB) == 0 else {
        status.result = "maintenance"; schedule.reset(scheduledSettings(), now: Date()); return
    }
    status.busy = true
    if isCapture { status.lastAttempt = Date() }
    status.result = isCapture ? "capturing" : operation == "mount" ? "mounting" : "unmounting"
    schedule.reset(scheduledSettings(), now: Date())
    do {
        if isCapture { try Data().write(to: privateFile("capture-in-progress"), options: .atomic) }
        if operation == "unmount" {
            try save(true, "volume-paused.json"); status.volumePaused = true
            schedule.reset(scheduledSettings(), now: Date())
        }
        let logURL = privateFile("last-capture.log")
        fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["asuser", String(owner), "/bin/bash", ServicePaths.root + "/collector/rtl9210-health", isCapture ? "service-probe" : "service-" + operation]
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root", "LC_ALL": "C"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = log; p.standardError = log
        p.terminationHandler = { child in
            try? log.close()
            queue.async {
                defer { flock(captureLock, LOCK_UN) }
                process = nil; status.busy = false
                let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                if !isCapture {
                    if child.terminationStatus == 0 {
                        if operation == "mount" {
                            do { try save(false, "volume-paused.json"); status.volumePaused = false; status.result = "mounted" }
                            catch { status.result = "volumeFailed" }
                        } else { status.result = "unmounted" }
                    } else { status.result = "volumeFailed" }
                    schedule.reset(scheduledSettings(), now: Date())
                    return
                }
                if child.terminationStatus == 0 {
                    let run = privateFile("latest").resolvingSymlinksInPath()
                    let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyyMMdd_HHmmss"
                    if run.path.hasPrefix(privateFile("runs").path + "/"),
                       let summary = try? String(contentsOf: run.appendingPathComponent("summary.txt"), encoding: .utf8),
                       let date = format.date(from: run.lastPathComponent),
                       date >= (status.lastAttempt ?? Date()).addingTimeInterval(-1),
                       let reading = Reading.parse(summary: summary, id: run.lastPathComponent, date: date) {
                        status.readings.removeAll { $0.id == reading.id }; status.readings.append(reading)
                        status.readings = Array(status.readings.sorted { $0.capturedAt < $1.capturedAt }.suffix(500))
                        do { try save(status.readings, "history.json"); status.result = "success" }
                        catch { status.result = "saveFailed"; status.settings.automatic = false }
                    } else { status.result = "invalidResult"; status.settings.automatic = false }
                } else if !text.contains("Unmounting ") && (text.contains("open files") || text.contains("I/O is active") || text.contains("Time Machine is running")) {
                    status.result = "skippedBusy"
                } else if !text.contains("Unmounting ") && (text.contains("found 0") || text.contains("not mounted")) {
                    status.result = "skippedOffline"
                } else {
                    status.result = "failedPaused"; status.settings.automatic = false
                }
                try? save(status.settings, "settings.json")
                if status.result == "success" || status.result.hasPrefix("skipped") { try? fm.removeItem(at: privateFile("capture-in-progress")) }
                // Failure keeps the marker and pauses automation; explicit manual retry is still possible.
                schedule.reset(scheduledSettings(), now: Date())
            }
        }
        process = p; try p.run()
    } catch {
        flock(captureLock, LOCK_UN)
        status.busy = false; process = nil; status.result = "launchFailed"; status.settings.automatic = false
        try? save(status.settings, "settings.json"); schedule.reset(scheduledSettings(), now: Date())
    }
}
func handle(_ request: ServiceRequest) -> ServiceStatus {
    var requestError: String?
    switch request.command {
    case "status", "log": break
    case "configure":
        if status.busy { requestError = "busy" }
        else if let settings = request.settings, settings.valid {
            if settings.automatic && !status.busy && fm.fileExists(atPath: privateFile("capture-in-progress").path) {
                requestError = "recoveryRequired"
            } else {
                do { try save(settings, "settings.json"); status.settings = settings; schedule.reset(scheduledSettings(), now: Date()) }
                catch { requestError = "saveFailed" }
            }
        } else { requestError = "invalidSettings" }
    case "mount", "unmount":
        if status.busy { requestError = "busy" }
        else { beginCapture(operation: request.command) }
    case "capture":
        if status.busy { requestError = "busy" }
        else if status.volumePaused == true { requestError = "volumePaused" }
        else if let lastManual, Date().timeIntervalSince(lastManual) < 60 { requestError = "rateLimited" }
        else { lastManual = Date(); beginCapture() }
    default: requestError = "unknownCommand"
    }
    var response = status; response.nextAttempt = schedule.next; response.error = requestError
    if request.command == "log" {
        response.log = (try? String(contentsOf: privateFile("last-capture.log"), encoding: .utf8)).map { String($0.suffix(65536)) } ?? "尚无后台采集日志。"
    }
    return response
}
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now() + 15, repeating: 15)
timer.setEventHandler {
    if schedule.due(scheduledSettings(), now: Date(), busy: status.busy) { beginCapture() }
}
timer.resume()
let server = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
guard server >= 0 else { exit(71) }
unlink(ServicePaths.socket)
var addr = ServiceIO.address()
let bound = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard bound == 0, chmod(ServicePaths.socket, 0o600) == 0, chown(ServicePaths.socket, owner, 0) == 0, listen(server, 8) == 0 else { exit(71) }
// The parent directory is root-owned; the enrolled UID cannot replace the socket or executable.
while true {
    let client = accept(server, nil, nil)
    if client < 0 { continue }
    ServiceIO.prepare(client)
    var uid: uid_t = 0; var gid: gid_t = 0
    if getpeereid(client, &uid, &gid) == 0 && uid == owner {
        do {
            let request = try JSONDecoder().decode(ServiceRequest.self, from: ServiceIO.readLine(client, limit: 4096))
            let response = queue.sync { handle(request) }
            try ServiceIO.writeLine(client, data: JSONEncoder().encode(response))
        } catch { }
    }
    close(client)
}
