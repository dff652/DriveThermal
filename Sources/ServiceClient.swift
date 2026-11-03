import Foundation
import AppKit

extension DriveModel {
    var serviceInstaller: URL? {
        guard let resource = Bundle.main.resourceURL else { return nil }
        let url = resource.appendingPathComponent("ServicePackage/DriveThermalInstaller")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    var modeDescription: String {
        guard let service = serviceStatus else { return "手动模式 · 后台服务未连接" }
        if service.volumePaused == true { return service.settings.automatic ? "自动采集已暂停 · 挂载后恢复" : "手动模式 · 已暂停采集" }
        return service.settings.automatic ? "自动采集 · 每 \(service.settings.intervalMinutes) 分钟" : "手动模式 · 后台服务已就绪"
    }
    var serviceResultText: String {
        guard let service = serviceStatus else { return "安装后台服务后，手动和自动采集均可使用首次批准的权限。" }
        switch service.result {
        case "ready": return "服务已就绪。"
        case "capturing": return "正在采集，完成后恢复挂载。"
        case "mounting": return "正在挂载已登记宗卷。"
        case "unmounting": return "正在安全卸载已登记宗卷。"
        case "mounted": return "已挂载，采集按当前模式恢复。"
        case "unmounted": return "已卸载，采集暂停；USB 仍供电，不保证降温。"
        case "volumeFailed": return "挂载／卸载未完成，请检查磁盘占用和服务日志。"
        case "success": return "上次采集成功，硬盘已恢复挂载。"
        case "skippedBusy": return "上次因磁盘占用或备份任务跳过，等待下一个间隔。"
        case "skippedOffline": return "上次因设备未连接或未挂载跳过。"
        case "skippedSession": return "登记用户未在本机登录，已跳过采集。"
        case "maintenance": return "后台服务正在维护，已跳过本次采集。"
        case "interrupted": return "上次采集被中断，自动模式已暂停；请先检查磁盘挂载状态。"
        case "failedPaused": return "采集失败，自动模式已暂停；请先检查磁盘及服务日志。"
        case "saveFailed": return "读数保存失败，自动模式已暂停。"
        default: return "服务出现异常，自动模式已暂停，请查看日志。"
        }
    }
    var wantsMount: Bool { !mount.mounted || serviceStatus?.volumePaused == true }
    var volumeActionTitle: String { wantsMount ? "挂载" : "卸载" }
    var canManageVolume: Bool {
        serviceStatus?.version == "2" && mount.connected && !busy && !serviceChecking && !installingService
    }
    var volumeHelp: String {
        guard serviceStatus?.version == "2" else { return "请先在设置中更新后台服务，以启用挂载／卸载。" }
        return "仅操作已登记宗卷。卸载后暂停采集；挂载后按原模式恢复。卸载不会切断 USB 电源。若已在 Finder 弹出整个设备，可能需要重新插拔。"
    }
    func toggleVolume() {
        guard canManageVolume else { return }
        sendService(ServiceRequest(command: wantsMount ? "mount" : "unmount"))
    }
    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }
    func refreshService() { sendService(ServiceRequest(command: "status"), quiet: true) }
    func showSettings() {
        if let service = serviceStatus { draftAutomatic = service.settings.automatic; draftMinutes = service.settings.intervalMinutes }
        settingsVisible = true
        refreshService()
    }
    func sendService(_ request: ServiceRequest, quiet: Bool = false) {
        guard !serviceChecking else { return }
        serviceChecking = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try ServiceIO.request(request) }
            DispatchQueue.main.async {
                self.serviceChecking = false
                switch result {
                case .success(let value):
                    let previous = self.serviceStatus
                    self.serviceStatus = value
                    if self.activeProcess == nil { self.busy = value.busy }
                    if request.command == "configure" && value.error == nil {
                        self.message = "采集设置已保存。"; self.draftAutomatic = value.settings.automatic; self.draftMinutes = value.settings.intervalMinutes
                    }
                    if let error = value.error {
                        self.message = error == "rateLimited" ? "请至少间隔 1 分钟再手动采集。" : error == "busy" ? "已有磁盘操作正在进行。" : error == "volumePaused" ? "硬盘已暂停采集，请先点击挂载。" : error == "recoveryRequired" ? "请先手动读取温度并确认恢复成功，再开启自动采集。" : "设置未生效：\(error)"
                    } else if ["capture", "mount", "unmount"].contains(request.command) || (previous?.busy == true && !value.busy) {
                        self.message = self.serviceResultText
                    }
                    if request.command == "log", let text = value.log {
                        let file = self.state.appendingPathComponent("service-capture.log")
                        do {
                            try text.write(to: file, atomically: true, encoding: .utf8)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                            NSWorkspace.shared.open(file)
                        } catch { self.message = "无法保存服务日志副本。" }
                    }
                    self.mergeServiceReadings(value.readings)
                    if previous?.busy == true && !value.busy { self.refreshMount() }
                    if value.busy {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak model = self] in model?.refreshService() }
                    }
                case .failure:
                    self.serviceStatus = nil
                    // Do not silently clear a known in-progress capture on IPC failure.
                    if !quiet { self.message = "后台服务未连接，请安装或检查服务。" }
                }
                self.onChange?()
            }
        }
    }
    func mergeServiceReadings(_ incoming: [Reading]) {
        guard !incoming.isEmpty else { return }
        var merged = Dictionary(readings.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for item in incoming where item.celsius.isFinite && (-40...150).contains(item.celsius) { merged[item.id] = item }
        let values = Array(merged.values.sorted { $0.capturedAt < $1.capturedAt }.suffix(500))
        guard values != readings else { return }
        readings = values
        do {
            let file = state.appendingPathComponent("history.json")
            try JSONEncoder().encode(values).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { message = "后台已采集，本机历史缓存保存失败。" }
    }
    func applySettings() {
        let settings = CaptureSettings(automatic: draftAutomatic, intervalMinutes: draftMinutes)
        guard settings.valid else { message = "采集间隔应为 5–1440 分钟。"; return }
        sendService(ServiceRequest(command: "configure", settings: settings))
    }
    func installService(remove: Bool = false) {
        guard !busy, !installingService, let installer = serviceInstaller else { return }
        installingService = true; message = nil
        let operation = remove ? "uninstall" : "install"
        // Quote both the shell path and AppleScript string. Never pass a password to the app.
        let shellPath = "'" + installer.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = shellPath + " " + operation + " " + String(getuid())
        let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"\(quoted)\" with administrator privileges"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            var result = ""
            var success = false
            do { try p.run(); result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; p.waitUntilExit(); success = p.terminationStatus == 0 }
            catch { result = error.localizedDescription }
            DispatchQueue.main.async {
                self.installingService = false
                self.message = success ? (remove ? "后台服务已卸载，历史记录保留。" : "后台服务已安装，请选择采集模式。") : "未完成服务安装／卸载：\(result)"
                if success && !remove && result.contains("Previous capture:") { self.message = "服务已更新；" + result }
                self.refreshService(); self.onChange?()
            }
        }
    }
}

import SwiftUI
struct CaptureSettingsView: View {
    @ObservedObject var model: DriveModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("采集模式与间隔").font(.title2.bold())
            Text(model.modeDescription).font(.headline)
            if model.serviceStatus == nil {
                Text("首次批准安装后台服务后，采集无需反复输入密码。服务仅操作已登记硬盘；不会保存你的密码。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button(model.installingService ? "等待系统授权…" : "安装并授权后台服务…") { model.installService() }
                    .disabled(model.serviceInstaller == nil || model.installingService || model.busy)
                if model.serviceInstaller == nil {
                    Text("此公开构建未包含本机采集器安装包。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Picker("采集模式", selection: $model.draftAutomatic) {
                    Text("手动").tag(false)
                    Text("自动").tag(true)
                }.pickerStyle(.segmented)
                HStack {
                    Text("间隔（分钟）")
                    TextField("5–1440", value: $model.draftMinutes, formatter: NumberFormatter())
                        .frame(width: 90).textFieldStyle(.roundedBorder)
                }.disabled(!model.draftAutomatic)
                HStack {
                    ForEach(CaptureSettings.presets, id: \.self) { minutes in
                        Button("\(minutes) 分钟") { model.draftMinutes = minutes }.disabled(!model.draftAutomatic)
                    }
                }
                Text("5–15 分钟适合短期观察；每次采集仍需短暂卸载硬盘。")
                    .font(.caption).foregroundStyle(.secondary)
                if let next = model.serviceStatus?.nextAttempt {
                    Text("下次尝试：\(next.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                }
                Text(model.serviceResultText).font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Button("查看服务日志") { model.sendService(ServiceRequest(command: "log")) }
                    Button("更新／修复服务…") { model.installService() }
                        .disabled(model.busy || model.installingService)
                }
                Button("应用设置") { model.applySettings() }
                    .buttonStyle(.borderedProminent).disabled(model.serviceChecking || model.installingService)
            }
            Text("每次采集会暂时卸载硬盘。读写、备份忙碌或本机未登录时跳过；休眠唤醒后重新计时，不补采。退出小窗应用后，自动采集仍会运行。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            DisclosureGroup("为什么还会提示访问可移除宗卷？") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("这是 macOS 文件隐私权限，与管理员安装验证不同，手动／自动模式都不能代替它。请在系统提示中允许，或到“文件与文件夹”检查相应程序的“可移除宗卷”。本地签名的开发版更新后可能需要重新允许。")
                    Button("打开文件与文件夹权限…") { model.openPrivacySettings() }
                }.font(.caption).padding(.top, 6)
            }.font(.system(size: 12))
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if model.serviceStatus != nil {
                    Button("卸载后台服务…") { model.installService(remove: true) }
                        .disabled(model.busy || model.installingService)
                }
                Spacer()
                Button("完成") { model.settingsVisible = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 470)
    }
}
