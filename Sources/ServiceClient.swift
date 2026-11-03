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
        draftIntervalText = String(draftMinutes)
        message = nil
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
                if request.command == "configure" { self.savingSettings = false }
                switch result {
                case .success(let value):
                    let previous = self.serviceStatus
                    self.serviceStatus = value
                    if self.activeProcess == nil { self.busy = value.busy }
                    if request.command == "configure" && value.error == nil {
                        if value.settings == request.settings {
                            self.message = "采集设置已保存。"; self.draftAutomatic = value.settings.automatic; self.draftMinutes = value.settings.intervalMinutes
                            self.settingsVisible = false
                        } else {
                            self.message = "服务返回的设置与所选值不一致，请重试。"
                        }
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
        guard !serviceChecking, !installingService, !busy, !savingSettings else { return }
        let settings = CaptureSettings(automatic: draftAutomatic, intervalMinutes: draftMinutes)
        guard settings.valid else { message = "采集间隔应为 5–1440 分钟。"; return }
        // Closing unchanged settings must not restart the collection countdown.
        if settings == serviceStatus?.settings { settingsVisible = false; return }
        savingSettings = true
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
    private var interval: Int? { Int(model.draftIntervalText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var validInterval: Bool { interval.map { (CaptureSettings.minimumMinutes...CaptureSettings.maximumMinutes).contains($0) } ?? false }
    private var hasChanges: Bool {
        guard let settings = model.serviceStatus?.settings else { return false }
        return model.draftAutomatic != settings.automatic || (model.draftAutomatic && interval != settings.intervalMinutes)
    }
    private var normalService: Bool {
        guard let service = model.serviceStatus else { return false }
        return ["ready", "success", "mounted"].contains(service.result) && service.volumePaused != true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("采集模式与间隔").font(.title2.bold())
            Text("当前生效：\(model.modeDescription)").font(.system(size: 13, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.serviceStatus == nil {
                        Text("首次批准安装后台服务后，采集无需反复输入密码。服务仅操作已登记硬盘，不会保存密码。")
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
                            TextField("5–1440", text: $model.draftIntervalText)
                                .frame(width: 90).textFieldStyle(.roundedBorder)
                        }.disabled(!model.draftAutomatic)
                        HStack {
                            ForEach(CaptureSettings.presets, id: \.self) { minutes in
                                Button("\(minutes) 分钟") { model.draftIntervalText = String(minutes) }
                                    .disabled(!model.draftAutomatic)
                            }
                        }
                        if model.draftAutomatic && !validInterval {
                            Text("请输入 5–1440 的整数分钟。").font(.caption).foregroundStyle(.red)
                        } else if model.draftAutomatic, let interval, interval <= 15 {
                            HStack(spacing: 6) {
                                InfoButton(title: "短间隔采集", text: "5–15 分钟适合临时观察。每次采集均需短暂卸载并恢复硬盘，长期使用可选择更长间隔，减少对磁盘使用的打扰。")
                                Text("短间隔适合临时观察").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if hasChanges {
                            Label("有未保存的修改，保存后生效", systemImage: "pencil.circle")
                                .font(.caption).foregroundStyle(.primary)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: model.busy ? "arrow.triangle.2.circlepath" : normalService ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(normalService ? Color.teal : Color.orange)
                                Text(normalService && !model.busy ? "后台服务正常" : model.serviceResultText)
                                    .font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            }
                            if let next = model.serviceStatus?.nextAttempt {
                                HStack(spacing: 6) {
                                    Text("下次计划采集：\(Calendar.current.isDateInToday(next) ? "今天 " + next.formatted(date: .omitted, time: .shortened) : next.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                    InfoButton(title: "计划采集时间", text: "这是当前已保存设置的计划时间。磁盘读写或备份忙碌、设备离线或本机未登录时可能跳过；休眠唤醒后重新计时，不补采。保存新的设置后重新计算时间。")
                                }
                            } else {
                                Text(model.serviceStatus?.volumePaused == true ? "硬盘已暂停采集，挂载后恢复。" : model.serviceStatus?.settings.automatic == true ? "暂无计划采集，请检查服务状态。" : "手动模式下不安排定时采集。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !normalService && !model.busy {
                                Button("查看服务日志") { model.sendService(ServiceRequest(command: "log")) }
                                    .disabled(model.serviceChecking || model.installingService)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Label("每次采集会短暂卸载硬盘。", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 12))
                    DisclosureGroup("采集与权限说明") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("磁盘读写、备份忙碌或本机未登录时跳过；休眠唤醒后重新计时，不补采。退出小窗应用后，后台自动采集仍会运行。")
                            Text("访问可移除宗卷是 macOS 文件隐私权限，与管理员安装验证不同。首次出现提示时需要允许；本地签名的开发版更新后可能需要重新允许。手动与自动模式都不能代替此权限。")
                            Button("打开文件与文件夹权限…") { model.openPrivacySettings() }
                        }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.system(size: 12))
                    if model.serviceStatus != nil {
                        DisclosureGroup("后台服务管理") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Button("查看服务日志") { model.sendService(ServiceRequest(command: "log")) }
                                    Button("更新／修复服务…") { model.installService() }
                                }
                                Divider()
                                Text("卸载后停止后台采集，保留已有历史记录。").font(.caption).foregroundStyle(.secondary)
                                Button("卸载后台服务…") { model.installService(remove: true) }
                            }.padding(.top, 8).disabled(model.busy || model.installingService || model.serviceChecking)
                        }.font(.system(size: 12))
                    }
                }.padding(.trailing, 6).padding(.vertical, 2)
            }.frame(maxHeight: 460)
            if let message = model.message {
                Label(message, systemImage: "info.circle").font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            HStack {
                Spacer()
                Button(model.serviceStatus == nil ? "关闭" : "取消") { model.settingsVisible = false }
                    .keyboardShortcut(.cancelAction).disabled(model.installingService)
                if model.serviceStatus != nil {
                    Button(model.savingSettings ? "正在保存…" : "保存并关闭") {
                        if model.draftAutomatic, let minutes = interval { model.draftMinutes = minutes }
                        model.applySettings()
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.serviceChecking || model.installingService || model.busy || (model.draftAutomatic && !validInterval))
                }
            }
        }.padding(24).frame(width: 470)
            .disabled(model.savingSettings)
            .interactiveDismissDisabled(model.savingSettings || model.installingService)
    }
}
