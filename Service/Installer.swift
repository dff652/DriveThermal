import Foundation
import Darwin

@main enum Installer {
    static func main() {
        do { try run() }
        catch { fputs("DriveThermal service: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static let fm = FileManager.default
    static func fail(_ text: String) -> NSError { NSError(domain: "DriveThermalInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func command(_ path: String, _ args: [String], required: Bool = true) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root"]
        try p.run(); p.waitUntilExit()
        if required && p.terminationStatus != 0 { throw fail("系统服务操作失败：\(p.terminationStatus)") }
    }
    static func securedDirectory(_ path: String, mode: Int) throws {
        var st = stat()
        if lstat(path, &st) == 0 {
            guard st.st_uid == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_mode & 0o022 == 0 else { throw fail("服务目录权限不安全") }
        } else {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: mode, .ownerAccountID: 0, .groupOwnerAccountID: 0])
        }
    }
    static func checkTree(_ path: String) throws {
        guard let enumerator = fm.enumerator(atPath: path) else { throw fail("找不到服务安装文件") }
        for case let item as String in enumerator {
            var st = stat()
            guard lstat(path + "/" + item, &st) == 0,
                  st.st_mode & S_IFMT == S_IFREG || st.st_mode & S_IFMT == S_IFDIR else { throw fail("安装包包含非普通文件") }
        }
    }
    static func rootTree(_ path: String) throws {
        try command("/bin/chmod", ["-RN", path])
        let paths = [path] + (fm.subpaths(atPath: path) ?? []).map { path + "/" + $0 }
        for item in paths {
            let attributes = try fm.attributesOfItem(atPath: item)
            let original = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let mode = attributes[.type] as? FileAttributeType == .typeDirectory || original & 0o111 != 0 ? 0o755 : 0o644
            try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: mode], ofItemAtPath: item)
        }
    }
    static func run() throws {
        guard geteuid() == 0, CommandLine.arguments.count == 3,
              ["install", "uninstall"].contains(CommandLine.arguments[1]),
              let uid = UInt32(CommandLine.arguments[2]), uid >= 501,
              let account = getpwuid(uid) else { throw fail("需要管理员批准并指定有效本机用户") }
        let home = String(cString: account.pointee.pw_dir)
        try securedDirectory("/Library/Application Support", mode: 0o755)
        try securedDirectory(ServicePaths.root, mode: 0o755)
        try securedDirectory(ServicePaths.state, mode: 0o700)
        let captureLock = open(ServicePaths.state + "/capture.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard captureLock >= 0 else { throw fail("无法锁定服务安装状态") }
        defer { close(captureLock) }
        guard flock(captureLock, LOCK_EX | LOCK_NB) == 0 else { throw fail("采集正在进行，请完成后再更新服务") }
        if fm.fileExists(atPath: ServicePaths.state + "/capture-in-progress") {
            // Query as the installed owner; the socket intentionally rejects other UIDs.
            guard seteuid(uid) == 0 else { throw fail("无法检查现有服务") }
            let snapshot = try? ServiceIO.request(ServiceRequest(command: "status"))
            guard seteuid(0) == 0 else { exit(77) }
            guard let snapshot, !snapshot.busy else { throw fail("采集中或无法确认状态，请稍后再更新服务") }
        }
        if let log = try? String(contentsOfFile: ServicePaths.state + "/last-capture.log", encoding: .utf8) {
            for line in log.split(separator: "\n") where line.contains("ERROR:") || line.contains("FATAL:") || line.contains("Permission") || line.contains("denied") || line.contains("not permitted") {
                print("Previous capture: " + line)
            }
        }
        try securedDirectory("/Library/LaunchDaemons", mode: 0o755)
        if CommandLine.arguments[1] == "uninstall" {
            try command("/bin/launchctl", ["bootout", "system/" + ServicePaths.label], required: false)
            if fm.fileExists(atPath: ServicePaths.plist) { try fm.removeItem(atPath: ServicePaths.plist) }
            if fm.fileExists(atPath: ServicePaths.socket) { try fm.removeItem(atPath: ServicePaths.socket) }
            // Preserve root-protected records for diagnostics. No private data is destroyed.
            print("后台服务已停用并取消注册，历史记录保留。")
            return
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let package = executable.deletingLastPathComponent()
        guard executable.lastPathComponent == "DriveThermalInstaller",
              fm.isExecutableFile(atPath: package.appendingPathComponent("DriveThermalService").path),
              fm.isExecutableFile(atPath: package.appendingPathComponent("collector/.build/rtl9210_health_probe").path) else { throw fail("本机采集服务安装包不完整") }
        try checkTree(package.path)
        let profile = home + "/Library/Application Support/DriveThermal/device.plist"
        var profileStat = stat()
        guard lstat(profile, &profileStat) == 0, profileStat.st_mode & S_IFMT == S_IFREG,
              profileStat.st_uid == uid, profileStat.st_size < 65536 else { throw fail("未找到该用户的有效设备登记") }
        let profileData = try Data(contentsOf: URL(fileURLWithPath: profile))
        guard let fields = try PropertyListSerialization.propertyList(from: profileData, format: nil) as? [String: Any],
              let uuid = fields["volume_uuid"] as? String, UUID(uuidString: uuid) != nil,
              let mount = fields["mount_path"] as? String, mount.hasPrefix("/Volumes/"), !mount.contains("\n"),
              fields["usb_vid"] as? String == "0x0bda", fields["usb_pid"] as? String == "0x9210" else { throw fail("设备登记不符合 RTL9210 采集要求") }
        try command("/bin/launchctl", ["bootout", "system/" + ServicePaths.label], required: false)
        try securedDirectory(ServicePaths.state, mode: 0o700)
        for name in ["DriveThermalService", "collector"] {
            let destination = ServicePaths.root + "/" + name
            if fm.fileExists(atPath: destination) { try fm.removeItem(atPath: destination) }
            try fm.copyItem(at: package.appendingPathComponent(name), to: URL(fileURLWithPath: destination))
            try rootTree(destination)
        }
        try profileData.write(to: URL(fileURLWithPath: ServicePaths.state + "/device.plist"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: ServicePaths.state + "/device.plist")
        try JSONEncoder().encode(uid).write(to: URL(fileURLWithPath: ServicePaths.root + "/owner.json"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ServicePaths.root + "/owner.json")
        let plist: [String: Any] = ["Label": ServicePaths.label,
            "ProgramArguments": [ServicePaths.root + "/DriveThermalService"], "RunAtLoad": true, "KeepAlive": true,
            "ThrottleInterval": 30, "ProcessType": "Background", "ExitTimeOut": 120,
            "AssociatedBundleIdentifiers": ["local.drivethermal.app"],
            "StandardOutPath": ServicePaths.state + "/service.log", "StandardErrorPath": ServicePaths.state + "/service-error.log"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: ServicePaths.plist), options: .atomic)
        try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o644], ofItemAtPath: ServicePaths.plist)
        try command("/bin/launchctl", ["enable", "system/" + ServicePaths.label])
        try command("/bin/launchctl", ["bootstrap", "system", ServicePaths.plist])
        print("后台采集服务已安装。")
    }
}
