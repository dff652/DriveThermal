import AppKit
import SwiftUI
import Charts
import UniformTypeIdentifiers

let appStateURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DriveThermal", isDirectory: true)

final class DriveModel: ObservableObject {
    @Published var readings: [Reading] = []
    @Published var mount = MountState(connected: false, mounted: false)
    @Published var busy = false
    @Published var message: String? = nil
    @Published var checking = false
    @Published var historyVisible = false
    @Published var aboutVisible = false
    @Published var detailsVisible = false
    @Published var helpVisible = false
    @Published var settingsVisible = false
    @Published var serviceStatus: ServiceStatus? = nil
    @Published var serviceChecking = false
    @Published var savingSettings = false
    @Published var installingService = false
    @Published var draftAutomatic = false
    @Published var draftMinutes = 180
    @Published var draftIntervalText = "180"
    @Published var pinned = false
    @Published var now = Date()
    let state = appStateURL
    lazy var eventLog = EventLog(directory: state)
    var collectorURL: URL? {
        guard let resource = Bundle.main.resourceURL else { return nil }
        let file = resource.appendingPathComponent("collector/rtl9210-health")
        return FileManager.default.isExecutableFile(atPath: file.path) ? file : nil
    }
    var canCapture: Bool { !busy && !serviceChecking && !installingService && serviceStatus?.volumePaused != true && mount.mounted && enrollment != nil && (collectorURL != nil || serviceStatus != nil) }
    var enrollment: Enrollment?
    var onChange: (() -> Void)?
    var timer: Timer?
    var activeProcess: Process?
    var last: Reading? { readings.last }
    var name: String { enrollment?.name ?? "尚未登记硬盘" }
    var captureHelp: String {
        serviceStatus != nil ? "使用已批准的后台服务采集，无需再次输入密码。仍会暂时卸载硬盘，请先关闭该盘的文件。" : collectorURL == nil ? "此构建未包含采集后端，可查看已有记录。采集功能需另行配置已授权的兼容后端。" : "通过 NVMe SMART 读取 SSD 综合温度与健康信息。读取时会暂时卸载硬盘并请求管理员验证，完成后自动恢复。请先关闭该盘的文件。"
    }
    var mountLabel: String {
        if busy {
            if serviceStatus?.result == "mounting" { return "正在挂载" }
            if serviceStatus?.result == "unmounting" { return "正在卸载" }
            return "采集中 · 稍后恢复挂载"
        }
        return mount.mounted ? "已挂载" : mount.connected ? "未挂载" : "未连接"
    }
    var age: String {
        guard let r = last else { return "尚无采集记录" }
        let seconds = max(0, Int(now.timeIntervalSince(r.capturedAt)))
        if seconds < 60 { return "不足 1 分钟前采集" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前采集" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前采集" }
        return "\(seconds / 86400) 天前采集"
    }
    init() {
        do {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { message = "无法创建应用数据目录：\(error.localizedDescription)" }
        enrollment = Enrollment(url: state.appendingPathComponent("device.plist"))
        if let data = try? Data(contentsOf: state.appendingPathComponent("history.json")),
           let items = try? JSONDecoder().decode([Reading].self, from: data) {
            readings = items.sorted { $0.capturedAt < $1.capturedAt }
        }
        eventLog.record(.appStarted)
        importLatest()
        refreshService()
        refreshMount()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.now = Date(); self?.refreshService(); self?.refreshMount(); self?.onChange?()
        }
    }
    func importLatest() {
        let link = state.appendingPathComponent("latest")
        let run = link.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: link.path),
              run.path.hasPrefix(state.appendingPathComponent("runs").path + "/"),
              let text = try? String(contentsOf: run.appendingPathComponent("summary.txt"), encoding: .utf8) else { return }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyyMMdd_HHmmss"
        guard let date = format.date(from: run.lastPathComponent),
              let item = Reading.parse(summary: text, id: run.lastPathComponent, date: date) else { return }
        // Enrich an existing snapshot after an app upgrade without another USB probe.
        if let index = readings.firstIndex(where: { $0.id == item.id }), readings[index] == item { return }
        if let index = readings.firstIndex(where: { $0.id == item.id }) {
            readings[index] = item
        } else {
            eventLog.record(.historyImported)
            readings.append(item); readings.sort { $0.capturedAt < $1.capturedAt }
        }
        if readings.count > 500 { readings.removeFirst(readings.count - 500) }
        do {
            let url = state.appendingPathComponent("history.json")
            try JSONEncoder().encode(readings).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { message = "读数已取得，但历史记录保存失败。" }
    }
    func refreshMount() {
        guard !busy, !checking, let e = enrollment else { return }
        checking = true
        DispatchQueue.global(qos: .utility).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            p.arguments = ["info", "-plist", e.uuid]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            var data = Data()
            do { try p.run(); data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit() } catch { }
            let value = MountState.parse(data, expected: e)
            DispatchQueue.main.async {
                self.checking = false
                if !self.busy { self.mount = value; self.onChange?() }
            }
        }
    }
    func capture() {
        guard canCapture else { return }
        if serviceStatus != nil {
            sendService(ServiceRequest(command: "capture")); return
        }
        // An installed but disconnected service must not race the legacy front door.
        if FileManager.default.fileExists(atPath: ServicePaths.plist) {
            message = "后台服务暂不可用，请先检查服务，避免重复采集。"; onChange?(); return
        }
        guard let script = collectorURL else { return }
        busy = true; message = nil; now = Date(); onChange?()
        let oldID = last?.id
        eventLog.record(.captureRequested)
        let log = state.appendingPathComponent("last-capture.log")
        do {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: log)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, "probe", "--confirm"]
            var environment = ProcessInfo.processInfo.environment
            environment["DRIVETHERMAL_STATE"] = state.path
            environment["RTL9210_HEALTH_CONFIG"] = state.appendingPathComponent("device.plist").path
            p.environment = environment
            p.standardOutput = output; p.standardError = output; p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { process in
                try? output.close()
                DispatchQueue.main.async {
                    self.activeProcess = nil; self.busy = false; self.now = Date()
                    self.eventLog.record(process.terminationStatus == 0 ? .captureSucceeded : .captureFailed, exitCode: process.terminationStatus)
                    if process.terminationStatus == 0 {
                        self.importLatest()
                        self.message = self.last?.id != oldID ? "采集完成，硬盘已恢复挂载。" : "采集结束，但未发现有效的新读数。"
                    } else {
                        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                        if text.contains("cancel") || text.contains("取消") || text.contains("password") || text.contains("User canceled") {
                            self.message = "管理员验证未完成，未更新温度。可在准备好后重试。"
                        } else if text.contains("open files") || text.contains("could not unmount") || text.contains("Time Machine is running") || text.contains("I/O is active") {
                            let processes = Set(text.components(separatedBy: .newlines).filter { $0.hasPrefix("c") && !$0.contains(" ") }.map { String($0.dropFirst()) }).sorted()
                            self.message = processes.isEmpty ? "硬盘正在使用，已停止采集。关闭该盘的文件和备份任务后重试。" : "硬盘被占用：" + processes.joined(separator: "、") + "。已停止采集，请稍后重试。"
                        } else if text.contains("did not return") {
                            self.message = "采集后未能确认恢复挂载。请先查看磁盘状态和采集日志。"
                        } else { self.message = "采集未完成，旧读数已保留。请查看采集日志。" }
                    }
                    self.refreshMount(); self.onChange?()
                }
            }
            activeProcess = p
            try p.run()
        } catch { eventLog.record(.captureLaunchFailed); activeProcess = nil; finishFailure("无法启动采集：\(error.localizedDescription)") }
    }
    func finishFailure(_ text: String) { busy = false; message = text; onChange?() }
    func openDisk() {
        guard mount.mounted, let e = enrollment else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: e.mountPath))
    }
    func openLog() {
        if serviceStatus != nil { sendService(ServiceRequest(command: "log")); return }
        let file = state.appendingPathComponent("last-capture.log")
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file) }
        else { message = "尚无采集日志。"; onChange?() }
    }
    func openEventLog() { NSWorkspace.shared.open(eventLog.file) }
    func exportDiagnostics() {
        let report = DiagnosticReport.make(build: .current, os: ProcessInfo.processInfo.operatingSystemVersionString,
            mounted: mount.mounted, enrolled: enrollment != nil, collectorAvailable: collectorURL != nil,
            busy: busy, reading: last, events: eventLog.recent())
        let panel = NSSavePanel()
        panel.title = "导出脱敏诊断报告"
        panel.message = "包含版本、系统、温度及应用事件；不包含序列号、卷名、个人路径和原始采集日志。"
        panel.nameFieldStringValue = "DriveThermal-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            eventLog.record(.diagnosticExported)
            message = "脱敏诊断报告已导出。发送前仍可自行检查内容。"
        } catch { message = "报告导出失败：\(error.localizedDescription)" }
        onChange?()
    }
}

final class HelpPresentation: ObservableObject {
    @Published var visible = false
}

struct InfoButton: View {
    let title: String
    let text: String
    @StateObject private var presentation = HelpPresentation()
    var body: some View {
        Button { presentation.visible.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless).accessibilityLabel(title).help(text)
        .popover(isPresented: $presentation.visible) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("关闭") { presentation.visible = false } }
            }.padding(16).frame(width: 280)
        }
    }
}

struct TemperatureChart: View {
    let readings: [Reading]
    var compact = true
    var body: some View {
        let series = TemperatureSeries(readings: readings)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("温度趋势").font(.system(size: 12, weight: .semibold))
                InfoButton(title: "温度曲线说明", text: "圆点为成功采集的实测值，虚线仅连接采样点，不代表连续监测。曲线显示最近 30 次采集；只有一个采样点时不画连线。")
                Spacer()
                Text("最近 \(series.values.count) 次采集").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if series.values.isEmpty {
                Text("尚无温度记录，成功采集后显示曲线。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: compact ? 90 : 150)
            } else {
                Chart(series.values) { r in
                    if series.values.count > 1 {
                        LineMark(x: .value("采集时间", r.capturedAt), y: .value("温度 °C", r.celsius))
                            .interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                            .foregroundStyle(Color.teal.opacity(0.75))
                    }
                    PointMark(x: .value("采集时间", r.capturedAt), y: .value("温度 °C", r.celsius))
                        .symbolSize(38).foregroundStyle(Color.teal)
                        .annotation(position: .top) {
                            if r.id == series.values.last?.id {
                                Text("\(Int(r.celsius.rounded())) °C")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.primary)
                            }
                        }
                        .accessibilityLabel(r.capturedAt.formatted(date: .abbreviated, time: .standard))
                        .accessibilityValue("\(r.celsius) 摄氏度")
                }
                .chartXScale(domain: series.timeRange)
                .chartYScale(domain: series.temperatureRange)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let degrees = value.as(Double.self) { Text("\(Int(degrees))°") }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: compact ? 3 : 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                if series.spansDays {
                                    Text(date, format: .dateTime.month().day().hour().minute())
                                } else {
                                    Text(date, format: .dateTime.hour().minute())
                                }
                            }
                        }
                    }
                }
                .frame(height: compact ? 100 : 170)
                .padding(.top, 4)
                .help(series.values.map { "\($0.capturedAt.formatted(date: .abbreviated, time: .standard)) · \(Int($0.celsius.rounded())) °C" }.joined(separator: "\n"))
                if series.values.count == 1 {
                    Text("再采集一次即可形成连线。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct HistoryView: View {
    let readings: [Reading]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("温度记录").font(.title2.bold())

            TemperatureChart(readings: readings, compact: false)
            HStack {
                Text("采集记录").font(.headline)
                Spacer()
                Text("共 \(readings.count) 条 · 最新在前").font(.caption).foregroundStyle(.secondary)
            }
            List(readings.reversed()) { r in
                HStack {
                    Text(r.capturedAt.formatted(date: .abbreviated, time: .standard)).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text("\(Int(r.celsius.rounded())) °C").font(.headline)
                }.padding(.vertical, 4)
            }.listStyle(.plain)
        }.padding(22).frame(width: 500, height: 500)
    }
}

struct MainView: View {
    @ObservedObject var model: DriveModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Image(systemName: "externaldrive.fill").font(.system(size: 25)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.system(size: 19, weight: .semibold))
                    Text("外置 SSD · 温度快照").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.pinned.toggle()
                    NSApp.windows.first(where: { $0.identifier?.rawValue == "DriveThermalMain" })?.level = model.pinned ? .floating : .normal
                } label: { Image(systemName: model.pinned ? "pin.fill" : "pin") }
                .buttonStyle(.borderless).help(model.pinned ? "取消窗口置顶" : "窗口置顶")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("上次测得 · SSD 内部温度").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Image(systemName: "thermometer.medium").foregroundStyle(.white.opacity(0.85))
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.last.map { String(Int($0.celsius.rounded())) } ?? "—")
                        .font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
                    Text("°C").font(.system(size: 27, weight: .light))
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small).tint(.white) }
                }.foregroundStyle(.white)
                Text(model.age).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                if let last = model.last {
                    Text(last.capturedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [Color(red: 0.07, green: 0.27, blue: 0.32), Color(red: 0.08, green: 0.43, blue: 0.46)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            VStack(spacing: 12) {
                detail("连接状态", model.mountLabel, icon: "cable.connector")
                detail("容量 / 可用", model.mount.mounted && !model.busy ? "\(MountState.capacity(model.mount.totalBytes)) / \(MountState.capacity(model.mount.freeBytes))" : "—", icon: "internaldrive")
                    .help("来自 macOS，每 15 秒刷新；APFS 显示整个共享容器的总容量与可用空间。1 GB = 10 亿字节。")
                detail("SMART 警告", model.last.map { $0.warning == 0 ? "上次采集无严重警告" : String(format: "警告代码 0x%02X", $0.warning) } ?? "尚无数据", icon: "checkmark.shield")
                HStack {
                    metric("已用寿命估计", model.last?.used.map { "\($0)%" } ?? "—")
                        .help("来自 SMART 的厂商寿命消耗估计；0% 不代表零磨损，不能换算成保证性的健康分数。")
                    Spacer()
                    metric("通电时间", model.last?.hours.map { "\($0) 小时" } ?? "—")
                    Spacer()
                    metric("介质错误", model.last?.errors.map(String.init) ?? "—")
                }.padding(.top, 4)
            }
            TemperatureChart(readings: model.readings)
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.teal)
                Text(model.modeDescription).font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("设置…") { model.showSettings() }.buttonStyle(.bordered)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 10))
            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 10) {
                Button { model.detailsVisible = true } label: {
                    navigationLabel("查看SMART详情", icon: "list.bullet.rectangle")
                }
                .buttonStyle(.plain).help("查看硬盘信息与上次 SMART 快照，不会重新采集")
                Button { model.historyVisible = true } label: {
                    navigationLabel("查看历史", icon: "chart.xyaxis.line")
                }
                .buttonStyle(.plain).disabled(model.readings.isEmpty)
                .opacity(model.readings.isEmpty ? 0.45 : 1)
                .help("查看已保存的温度记录与趋势")
            }
            HStack(spacing: 10) {
                Button(model.busy ? "处理中…" : "读取温度") { model.capture() }
                    .buttonStyle(.borderedProminent).tint(.teal).controlSize(.large)
                    .disabled(!model.canCapture)
                    .help(model.captureHelp)
                Button { model.helpVisible.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless).accessibilityLabel("采集说明")
                    .help(model.captureHelp)
                    .popover(isPresented: $model.helpVisible) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("采集说明").font(.headline)
                            Text(model.captureHelp)
                            Text("支持手动与定时采集。菜单栏显示上次读数；打开详情不会重新采集。")
                                .foregroundStyle(.secondary)
                        }.font(.system(size: 12)).padding(18).frame(width: 300)
                    }
                Spacer()
                Button { model.toggleVolume() } label: {
                    Label(model.volumeActionTitle, systemImage: model.wantsMount ? "externaldrive.badge.plus" : "eject")
                }.buttonStyle(.bordered).disabled(!model.canManageVolume).help(model.volumeHelp)
                Menu {
                    Button("采集模式与间隔…") { model.showSettings() }
                    Button("在 Finder 中打开硬盘") { model.openDisk() }.disabled(!model.mount.mounted || model.busy)
                    Button("查看采集日志") { model.openLog() }
                    Button("查看应用事件日志") { model.openEventLog() }
                    Button("导出脱敏诊断报告…") { model.exportDiagnostics() }
                    Divider()
                    Button("关于 DriveThermal") { model.aboutVisible = true }
                    Button("刷新连接状态") { model.refreshMount() }.disabled(model.busy)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
            }
            HStack {
                Button("DriveThermal \(BuildInfo.current.version)") { model.aboutVisible = true }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "lock.shield").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("采集记录保存在本机；无遥测或自动上传。")
                    .accessibilityLabel("采集记录本机保存")
            }
        }.padding(24).frame(width: 420)
            .background(Color(nsColor: .windowBackgroundColor))
            .sheet(isPresented: $model.historyVisible) {
                VStack(spacing: 0) {
                    HistoryView(readings: model.readings)
                    HStack { Spacer(); Button("关闭") { model.historyVisible = false }.keyboardShortcut(.defaultAction) }
                        .padding(.horizontal, 22).padding(.bottom, 18)
                }
            }
            .sheet(isPresented: $model.aboutVisible) {
                AboutView(model: model)
            }
            .sheet(isPresented: $model.detailsVisible) {
                SMARTView(model: model)
            }
            .sheet(isPresented: $model.settingsVisible) {
                CaptureSettingsView(model: model)
            }
    }
    func navigationLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(title).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
        }
        .font(.system(size: 12)).foregroundStyle(Color.primary)
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.teal.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.teal.opacity(0.45), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    func detail(_ key: String, _ value: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            Text(key).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium))
        }
    }
    func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .medium, design: .rounded))
        }
    }
}

struct SMARTView: View {
    @ObservedObject var model: DriveModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("硬盘与 SMART").font(.title2.bold())
                Spacer()
                InfoButton(title: "SMART 快照说明", text: "查看详情只读取已保存的快照，不会重新采集。缺少的字段显示 —；断开硬盘后仍可查看上次数据。")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("容量 · 当前系统信息").font(.headline)
                        InfoButton(title: "容量说明", text: "容量每 15 秒刷新；APFS 多个卷共享容器空间。GB 使用十进制单位。")
                    }
                    row("容量范围", model.mount.isAPFS ? "APFS 共享容器" : "当前卷")
                    row("总容量", model.mount.mounted && !model.busy ? MountState.capacity(model.mount.totalBytes) : "—")
                    row("可用空间", model.mount.mounted && !model.busy ? MountState.capacity(model.mount.freeBytes) : "—")
                    Divider()
                    Text("SMART · 上次成功采集").font(.headline)
                    if let r = model.last {
                        Text(r.capturedAt.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        row("型号", r.model)
                        row("固件", r.smart?.firmware ?? "—")
                        row("SSD 综合温度", "\(Int(r.celsius.rounded())) °C", help: "NVMe SMART 综合温度，不是桥接芯片或外壳温度。")
                        row("严重警告", String(format: "0x%02X", r.warning) + (r.warning == 0 ? " · 无严重警告" : " · 请检查采集日志"))
                        row("备用空间", r.spare.map { "\($0)%" } ?? "—", help: "SSD 内部备用容量比例，与文件系统可用空间无关。")
                        row("备用空间警告阈值", r.smart?.spareThreshold ?? "—")
                        row("已用寿命估计", r.used.map { "\($0)%" } ?? "—", help: "厂商估计的寿命消耗，可以超过 100%；不是保证性的健康评分。")
                        Divider()
                        Text("累计读写").font(.headline)
                        row("累计读取", SMARTDetails.dataAmount(r.smart?.dataRead), help: "SMART 累计计数 × 512,000 字节；不是当前读写速度。原始计数：\(r.smart?.dataRead ?? "—")")
                        row("累计写入", SMARTDetails.dataAmount(r.smart?.dataWritten), help: "SMART 累计计数 × 512,000 字节；不是当前读写速度。原始计数：\(r.smart?.dataWritten ?? "—")")
                        row("主机读取命令", r.smart?.readCommands ?? "—")
                        row("主机写入命令", r.smart?.writeCommands ?? "—")
                        row("控制器忙碌时间", r.smart?.busyMinutes.map { "\($0) 分钟" } ?? "—")
                        Divider()
                        Text("运行与错误记录").font(.headline)
                        row("通电时间", r.hours.map { "\($0) 小时" } ?? "—")
                        row("通电次数", r.smart?.powerCycles ?? "—")
                        row("非正常断电次数", r.smart?.unsafeShutdowns ?? "—", help: "控制器未收到正常关机通知的累计次数，不等于磁盘损坏次数。")
                        row("介质 / 数据完整性错误", r.errors.map(String.init) ?? "—")
                        row("错误日志条目", r.smart?.errorLogEntries ?? "—")
                    } else {
                        Text("尚无有效 SMART 快照。").foregroundStyle(.secondary)
                    }
                }.padding(.trailing, 8)
            }
            HStack { Spacer(); Button("关闭") { model.detailsVisible = false }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 490, height: 610)
    }
    func row(_ title: String, _ value: String, help: String = "") -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            if !help.isEmpty { InfoButton(title: title + "说明", text: help) }
            Spacer(minLength: 14)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 12)).help(help)
    }
}

struct AboutView: View {
    @ObservedObject var model: DriveModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "externaldrive.fill").font(.system(size: 30)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DriveThermal").font(.title2.bold())
                    Text("版本 \(BuildInfo.current.label)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text("桌面与菜单栏硬盘温度快照工具").font(.subheadline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Link("维护者：dff652", destination: BuildInfo.maintainerURL)
                        Link("GitHub 项目与问题反馈", destination: BuildInfo.repositoryURL)
                    }
                    Divider()
                    Text("致谢").font(.headline)
                    Text("感谢 RazeBerry 的 rtl9210-health-monitor，为本机采集适配提供 USB 传输与 NVMe 健康数据读取实现。")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Link("RazeBerry/rtl9210-health-monitor", destination: URL(string: "https://github.com/RazeBerry/rtl9210-health-monitor")!)
                        .font(.system(size: 12))
                    DisclosureGroup("版本与开源说明") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("构建：\(BuildInfo.current.revision)\n构建时间（UTC）：\(BuildInfo.current.builtAt)")
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            Text("界面与采集接口采用 MIT 许可证。")
                            Text(model.collectorURL == nil ? "此构建仅包含界面与采集接口。USB 采集后端未包含在公开源码中。" : "本机采集器基于 rtl9210-health-monitor 并作适配。其上游尚无明确许可证，未纳入公开仓库。")
                        }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }.font(.system(size: 12))
                    HStack {
                        Label("记录仅保存在本机", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                        InfoButton(title: "数据与隐私", text: "无遥测或自动上传。诊断报告由你选择是否导出和分享；分享前仍可自行检查内容。")
                    }
                }.padding(.trailing, 6).padding(.vertical, 2)
            }.frame(maxHeight: 390)
            HStack {
                Button("导出脱敏报告…") { model.exportDiagnostics() }
                Spacer()
                Button("关闭") { model.aboutVisible = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 440)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: DriveModel!
    var window: NSWindow!
    var item: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "关于 DriveThermal", action: #selector(showAbout), keyEquivalent: ""); about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DriveThermal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = mainMenu
        model = DriveModel()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let root = MainView(model: model)
        let hosting = NSHostingView(rootView: root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 615), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("DriveThermalMain")
        window.title = "DriveThermal"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.center(); window.setFrameAutosaveName("DriveThermalMain")
        model.onChange = { [weak self] in self?.updateMenu() }
        updateMenu(); showWindow()
    }
    func updateMenu() {
        if let hosting = window?.contentView {
            let size = hosting.fittingSize
            if size.height > 100 && abs(window.contentLayoutRect.height - size.height) > 1 {
                window.setContentSize(size)
            }
        }
        let temperature = model.last.map { "\(Int($0.celsius.rounded()))°" } ?? "—°"
        item.button?.title = model.busy ? "采集中…" : temperature + (model.mount.mounted ? "" : " · 离线")
        item.button?.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "DriveThermal")
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "\(model.name)：上次温度 \(temperature)，\(model.age)"
        let menu = NSMenu()
        menu.addItem(withTitle: "\(model.name) · \(model.mountLabel)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: model.age, action: nil, keyEquivalent: "")
        menu.addItem(withTitle: model.modeDescription, action: nil, keyEquivalent: "")
        let settings = menu.addItem(withTitle: "采集模式与间隔…", action: #selector(showSettings), keyEquivalent: ""); settings.target = self
        menu.addItem(.separator())
        let show = menu.addItem(withTitle: "显示桌面小窗", action: #selector(showWindow), keyEquivalent: ""); show.target = self
        let capture = menu.addItem(withTitle: "读取温度（会暂时卸载硬盘）", action: #selector(capture), keyEquivalent: ""); capture.target = self; capture.isEnabled = model.canCapture
        let volume = menu.addItem(withTitle: model.wantsMount ? "挂载宗卷并恢复采集模式" : "卸载宗卷并暂停采集", action: #selector(toggleVolume), keyEquivalent: "")
        volume.target = self; volume.isEnabled = model.canManageVolume; volume.toolTip = model.volumeHelp
        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "关于 DriveThermal \(BuildInfo.current.version)", action: #selector(showAbout), keyEquivalent: ""); about.target = self
        let diagnostics = menu.addItem(withTitle: "导出脱敏诊断报告…", action: #selector(exportDiagnostics), keyEquivalent: ""); diagnostics.target = self
        let logs = menu.addItem(withTitle: "查看采集日志", action: #selector(openLogs), keyEquivalent: ""); logs.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 DriveThermal", action: #selector(quit), keyEquivalent: "q"); quit.target = self; quit.isEnabled = !model.busy
        menu.autoenablesItems = false; item.menu = menu
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showSettings() { showWindow(); model.showSettings() }
    @objc func capture() { showWindow(); model.capture() }
    @objc func toggleVolume() { showWindow(); model.toggleVolume() }
    @objc func showAbout() { showWindow(); model.historyVisible = false; model.aboutVisible = true }
    @objc func exportDiagnostics() { showWindow(); model.exportDiagnostics() }
    @objc func openLogs() { model.openLog() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.busy {
            let alert = NSAlert(); alert.messageText = "请等待当前磁盘操作完成"; alert.informativeText = "完成后即可退出 DriveThermal。"; alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}

@main enum DriveThermalMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
