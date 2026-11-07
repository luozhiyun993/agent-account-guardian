import AppKit
import Foundation
import GuardianCore

struct GuardianEvent: Identifiable, Codable {
    var id = UUID()
    var time = Date()
    var text: String
}

@MainActor
final class GuardianModel: ObservableObject {
    @Published var state: ProtectionState
    @Published var local: LocalHealth = .unknown("正在读取系统代理与路由状态…")
    @Published private(set) var transport: NetworkTransport?
    @Published var exit: ExitHealth = .unknown("正在检测出口…")
    @Published var events: [GuardianEvent] = []
    @Published var notice = ""
    @Published var checking = false
    @Published var stopping = false
    @Published var savingError: String?
    @Published var simulationOutput: [String] = []
    @Published var targetCount: Int?
    @Published var lastChecked: Date?
    private let store = StateStore()
    private var localTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var lastNetworkUpdate = Date.distantPast
    private var revision = 0
    private var recovering = false
    private var checkingLocal = false
    private var localRevision = 0
    private var localChecked = Date.distantPast
    private var wakeObserver: NSObjectProtocol?
    private var lastConfirmedTransport: NetworkTransport?

    init() {
        do {
            state = try store.load()
            state.enabled = false
        } catch {
            state = ProtectionState()
            state.lockedReason = "设置文件无法读取，请重新保存设置后检查并解锁。"
            savingError = "无法读取原有设置：\(error.localizedDescription)"
        }
        let logURL = store.directory.appendingPathComponent("events.json")
        if let data = try? Data(contentsOf: logURL), let saved = try? JSONDecoder().decode([GuardianEvent].self, from: data) {
            events = Array(saved.prefix(200))
        }
        record("应用已打开。监控处于观察模式，启用保护后才会执行急停。")
        persist()
        localTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshLocal()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        networkTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if Date().timeIntervalSince(self.lastNetworkUpdate) >= 10 { await self.refreshExit() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.revision += 1
                self.exit = .unknown("系统刚刚唤醒，重新检测出口。")
                self.local = .unknown("系统刚刚唤醒，重新检测代理。")
                self.localChecked = .distantPast
                self.lastNetworkUpdate = .distantPast
                self.record("系统唤醒：旧检测结果已失效，等待重新检查。")
            }
        }
    }

    var decision: Decision {
        let currentLocal: LocalHealth = Date().timeIntervalSince(localChecked) < 8
            ? local : .unknown("代理检查结果已过期，等待重新检测。")
        return GuardianPolicy.evaluate(settings: state.settings, local: currentLocal, exit: exit, previousIP: state.lastIP)
    }

    var statusTitle: String {
        if state.lockedReason != nil { return "保护已锁定" }
        if !state.enabled { return "观察模式" }
        switch decision {
        case .allow, .warn: return "保护运行中"
        case .wait: return "等待网络确认"
        case .trip: return "检测到异常"
        }
    }

    var statusDetail: String {
        if let reason = state.lockedReason { return reason }
        if !state.enabled { return "正在检测环境。启用保护后，异常将触发急停。" }
        switch decision {
        case .allow: return "启动门禁已就绪，正在持续检查代理与出口。"
        case .warn(let reason), .wait(let reason), .trip(let reason): return reason
        }
    }

    var currentObservation: ExitObservation? {
        if case .known(let result) = exit { return result }
        return nil
    }

    var networkGuidance: String {
        if case .systemHTTPS = transport {
            return "系统代理模式：Claude Code 请通过本应用启动，其他入口可能不跟随系统代理。"
        }
        return "自动识别系统 HTTPS 代理或实际隧道路由，不依赖代理软件名称。"
    }

    func record(_ text: String) {
        if events.first?.text == text { return }
        events.insert(GuardianEvent(text: text), at: 0)
        events = Array(events.prefix(200))
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: store.directory.appendingPathComponent("events.json"), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                ofItemAtPath: store.directory.appendingPathComponent("events.json").path)
        }
    }

    func persist() {
        state.heartbeat = Date()
        do { try store.save(state) }
        catch {
            savingError = "无法保存保护状态：\(error.localizedDescription)"
            state.lockedReason = "保护状态无法保存，启动门禁保持关闭。"
        }
    }

    func refreshLocal() async {
        guard !checkingLocal else { return }
        checkingLocal = true
        defer { checkingLocal = false }
        let settings = state.settings
        let capturedRevision = revision
        let result = await Task.detached { (LocalInspector.inspectConnection(), ProcessInspector.protectedProcesses(settings: settings)) }.value
        guard revision == capturedRevision else { return }
        let connection = result.0
        if connection.transport != transport {
            revision += 1
            exit = .unknown("网络路径已变化，等待新的出口检测。")
            lastNetworkUpdate = .distantPast
            transport = connection.transport
        }
        if let newTransport = connection.transport {
            if let previous = lastConfirmedTransport, newTransport.requiresProcessRestart(after: previous),
               state.enabled, state.lockedReason == nil {
                state.observe(.trip("系统代理路径已切换，已有进程可能仍使用旧代理，请检查并手动恢复。"))
                record("已锁定：系统代理路径变化，等待手动恢复。")
                notice = state.lockedReason ?? ""
            }
            lastConfirmedTransport = newTransport
        }
        var health = connection.health
        if result.1 == nil, case .healthy = health {
            health = .unknown("无法读取受保护进程，启动门禁保持关闭。")
        }
        if health != local { record("代理检查：\(health.summary)") }
        local = health
        localChecked = Date()
        localRevision += 1
        targetCount = result.1?.count
        applyDecision()
        persist()
        if state.enabled, state.lockedReason != nil { await enforceLock() }
    }

    func refreshExit() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        guard let requestTransport = transport else {
            exit = .unknown("尚未确认系统代理或隧道路径，暂不发送出口探针。")
            lastNetworkUpdate = Date()
            return
        }
        let capturedRevision = revision
        let result = await ExitInspector.inspect(transport: requestTransport)
        await refreshLocal()
        guard revision == capturedRevision, transport == requestTransport else { return }
        exit = result
        lastChecked = Date()
        lastNetworkUpdate = Date()
        switch result {
        case .known(let observation):
            if let previous = state.lastIP, previous != observation.ip {
                record("出口 IP 发生变化；当前地区 \(observation.country)。")
            }
            if case .wait = decision {} else { recordNetworkResult(observation) }
        case .unknown(let reason): record(reason)
        }
        applyDecision()
        if case .known(let observation) = result { state.lastIP = observation.ip }
        persist()
        if state.enabled, state.lockedReason != nil { await enforceLock() }
    }

    private func recordNetworkResult(_ observation: ExitObservation) {
        let entry = "出口检测完成：\(observation.country) · \(decision.mayLaunch ? "规则通过" : "规则未通过")。"
        if !events.prefix(5).contains(where: { $0.text == entry }) { record(entry) }
    }

    private func applyDecision() {
        let wasLocked = state.lockedReason
        state.observe(decision)
        if wasLocked == nil, let reason = state.lockedReason {
            record("已锁定：\(reason)")
            notice = "已触发保护：\(reason)"
            NSSound.beep()
        }
    }

    func enableProtection() {
        state.enabled = true
        record("用户启用保护。锁定期间将持续终止选中的 Claude 进程，包括外部启动。")
        applyDecision()
        persist()
        Task { await refreshLocal(); await refreshExit() }
    }

    func pauseProtection() {
        state.enabled = false
        revision += 1
        record("用户暂停保护；不再执行急停。已有锁定保持。")
        persist()
    }

    func saveSettings(_ settings: GuardianSettings) {
        if let error = settings.validationError { notice = error; return }
        state.settings = settings
        revision += 1
        exit = .unknown("设置已更改，正在重新检测。")
        lastNetworkUpdate = .distantPast
        savingError = nil
        persist()
        record("保护规则已保存；已有锁定不会自动解除。")
        notice = savingError ?? "设置已保存。"
        Task { await refreshLocal(); await refreshExit() }
    }

    func recheck() {
        Task { await refreshLocal(); await refreshExit() }
    }

    private func freshCheck() async -> Decision {
        guard !checking, !checkingLocal else { return .wait("正在检查，请等待当前检测完成后重试。") }
        let capturedRevision = revision
        let oldLocalRevision = localRevision
        await refreshLocal()
        await refreshExit()
        guard revision == capturedRevision, localRevision > oldLocalRevision,
              Date().timeIntervalSince(lastNetworkUpdate) < 2 else {
            return .wait("本次检查未完成或设置发生变化，请重试。")
        }
        return decision
    }

    func recover() {
        guard !recovering else { return }
        recovering = true
        Task {
            defer { recovering = false }
            guard state.enabled else { notice = "请先启用保护，再进行手动恢复。"; return }
            let result = await freshCheck()
            guard savingError == nil, !stopping, state.recover(result) else {
                notice = "尚不能解除锁定：请等待检测完成，并确保代理、出口及设置全部通过。"
                return
            }
            persist()
            notice = "检查通过，已解除锁定。不会自动重新打开 Claude。"
            record(notice)
        }
    }

    func enforceLock() async {
        guard !stopping, state.enabled, state.lockedReason != nil else { return }
        stopping = true
        defer { stopping = false }
        let settings = state.settings
        let targets = await Task.detached { ProcessInspector.protectedProcesses(settings: settings) }.value
        guard state.enabled, state.lockedReason != nil else { return }
        guard let targets else {
            record("急停失败：无法读取目标进程。锁定保持，请手动关闭 Claude。")
            return
        }
        guard !targets.isEmpty else { return }
        let report = await Task.detached { await ProcessStopper.stop(targets) }.value
        record("急停结果：已终止 \(report.stopped) 个进程，失败 \(report.failed) 个。\(report.inspectionFailed ? "无法完成进程复核，请手动检查。" : "")")
        targetCount = await Task.detached { ProcessInspector.protectedProcesses(settings: settings)?.count }.value
    }

    func realStopTest() {
        guard state.enabled else { notice = "请先启用保护，才能执行真实急停测试。"; return }
        state.lockedReason = "用户触发真实急停测试。"
        persist()
        record("用户确认真实急停测试，保护进入锁定。")
        Task { await enforceLock() }
    }

    func launchDesktop() {
        Task {
            let result = await freshCheck()
            guard state.settings.protectDesktop, savingError == nil, state.permitsLaunch(result) else {
                notice = "启动门禁未通过：请启用保护、完成检查，并解除锁定。"; return
            }
            let candidates = [URL(fileURLWithPath: "/Applications/Claude.app"),
                              FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app")]
            guard let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                notice = "未找到 Claude.app。"; return
            }
            do {
                _ = try await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                record("启动检查通过，已打开 Claude Desktop。")
            } catch { notice = "无法启动 Claude：\(error.localizedDescription)" }
        }
    }

    func launchCLI() {
        Task {
            let result = await freshCheck()
            guard state.settings.protectCLI, savingError == nil, state.permitsLaunch(result) else {
                notice = "启动门禁未通过：请启用保护、完成检查，并解除锁定。"; return
            }
            guard ProcessInspector.claudeCommand() != nil, let executable = Bundle.main.executableURL else {
                notice = "未找到 Claude Code，请先安装官方 CLI。"; return
            }
            do {
                let script = store.directory.appendingPathComponent("Launch Claude Code.command")
                let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                try "#!/bin/zsh\nexec \(quoted) --guarded-cli\n".write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                    notice = "未找到 Terminal。"; return
                }
                _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal,
                                                      configuration: NSWorkspace.OpenConfiguration())
                record("已请求打开 Claude Code 终端；执行前会再次检查门禁。")
            } catch { notice = "无法启动终端：\(error.localizedDescription)" }
        }
    }

    func simulate(_ scenario: String) {
        var settings = state.settings
        var sandbox = ProtectionState()
        sandbox.enabled = true
        sandbox.heartbeat = Date()
        let healthy = LocalHealth.healthy(interface: "演练网卡")
        let safeIP = settings.pinEnabled ? settings.pinnedIP : "8.8.8.8"
        let healthyExit = ExitHealth.known(ExitObservation(ip: safeIP, country: settings.country))
        let result: Decision
        switch scenario {
        case "网络超时":
            result = GuardianPolicy.evaluate(settings: settings, local: healthy, exit: .unknown("模拟网络超时"))
        case "地区漂移":
            result = GuardianPolicy.evaluate(settings: settings, local: healthy,
                exit: .known(ExitObservation(ip: safeIP, country: settings.country == "JP" ? "US" : "JP")))
        case "IP 不匹配":
            settings.pinEnabled = true
            settings.pinnedIP = "8.8.8.8"
            result = GuardianPolicy.evaluate(settings: settings, local: healthy,
                exit: .known(ExitObservation(ip: "1.1.1.1", country: settings.country)))
        default:
            result = GuardianPolicy.evaluate(settings: settings, local: .unsafe("模拟代理路径失效"), exit: healthyExit)
        }
        sandbox.observe(result)
        var lines = ["模拟：\(scenario)", "启动门禁：\(result.mayLaunch ? "允许" : "阻止")",
                     "运行进程：\(sandbox.lockedReason == nil ? "保留，不急停" : "将触发急停（本次不执行）")",
                     "锁定状态：\(sandbox.lockedReason == nil ? "未锁定" : "已锁定")"]
        if sandbox.lockedReason != nil {
            sandbox.observe(.allow)
            lines.append("网络恢复：\(sandbox.lockedReason != nil ? "仍锁定" : "已解锁")")
            let recovered = sandbox.recover(.allow)
            lines.append("手动恢复 + 检查通过：\(recovered ? "已解锁" : "失败")")
        }
        lines.append("演练完成：真实设置、锁定状态和进程均未改变。")
        simulationOutput = lines
    }
}
