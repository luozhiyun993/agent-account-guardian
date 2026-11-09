import AppKit
import SwiftUI
import GuardianCore
import Darwin

@main
enum GuardianEntry {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--guarded-cli") {
            CLIEntry.run()
        } else {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.local.agent-account-guardian")
                .filter { $0.processIdentifier != getpid() }
            if let existing = others.first {
                existing.activate(options: [.activateIgnoringOtherApps])
                return
            }
            GuardianApp.main()
        }
    }
}

struct GuardianApp: App {
    @NSApplicationDelegateAdaptor(GuardianAppDelegate.self) private var appDelegate
    @StateObject private var model = GuardianModel()

    var body: some Scene {
        Window("Account Guardian", id: "main") {
            GuardianView(model: model)
                .frame(minWidth: 980, minHeight: 720)
                .modifier(MainWindowReopenHandler(delegate: appDelegate))
        }
        .defaultSize(width: 1080, height: 800)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Account Guardian") { confirmQuit() }.keyboardShortcut("q")
            }
        }
        MenuBarExtra(model.statusTitle, systemImage: model.state.lockedReason != nil ? "exclamationmark.triangle.fill" : "lock.fill") {
            MenuContents(model: model)
            Divider()
            Button("退出并停止保护") { confirmQuit() }
        }
    }

    private func confirmQuit() {
        if model.state.enabled {
            let alert = NSAlert()
            alert.messageText = "退出后将停止持续监控和急停保护"
            alert.informativeText = "当前 Claude 可以继续运行。异常锁定会保存，下次打开后仍需要手动恢复。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "退出并停止保护")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        model.pauseProtection()
        NSApplication.shared.terminate(nil)
    }
}

struct MenuContents: View {
    @ObservedObject var model: GuardianModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.statusTitle)
        Text(model.statusDetail)
        Divider()
        Text("网络：\(model.networkStatus.summary)")
        Text("进程：\(model.processStatus.summary)")
        Divider()
        Button("打开控制面板") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("检查并解除锁定") { model.recover() }
            .disabled(model.state.lockedReason == nil || !model.state.enabled)
    }
}

enum CLIEntry {
    static func run() {
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached {
            defer { semaphore.signal() }
            let store = StateStore()
            do {
                let original = try store.load()
                guard original.enabled, original.lockedReason == nil, original.settings.protectCLI,
                      Date().timeIntervalSince(original.heartbeat) < 8 else {
                    fail("守护应用未启用、已锁定或不在线。请在主窗口完成检查。")
                    return
                }
                let connection = LocalInspector.inspectConnection()
                guard let transport = connection.transport else {
                    fail("没有可确认的系统代理或隧道路径。")
                    return
                }
                let exit = await ExitInspector.inspect(transport: transport)
                let confirmed = LocalInspector.inspectConnection()
                let decision = GuardianPolicy.evaluate(settings: original.settings, local: confirmed.health, exit: exit)
                let current = try store.load()
                guard confirmed.transport == transport, current.settings == original.settings, current.permitsLaunch(decision),
                      let command = ProcessInspector.claudeCommand(settings: current.settings) else {
                    fail("代理或出口检查未通过，或保护状态已变化。Claude Code 未启动。")
                    return
                }
                let originalEnvironment = ProcessInfo.processInfo.environment
                let environment = transport.cliEnvironment(from: originalEnvironment)
                for key in originalEnvironment.keys where environment[key] == nil { unsetenv(key) }
                for (key, value) in environment where originalEnvironment[key] != value { setenv(key, value, 1) }
                print("保护检查通过，正在启动 Claude Code。")
                let strings = [command.path] + Array(CommandLine.arguments.dropFirst(2))
                let pointers = strings.map { strdup($0) } + [nil]
                defer { pointers.forEach { if let pointer = $0 { free(pointer) } } }
                command.path.withCString { executable in
                    pointers.withUnsafeBufferPointer { buffer in _ = execv(executable, buffer.baseAddress!) }
                }
                fail("无法执行 Claude Code。")
            } catch { fail("无法读取保护状态：\(error.localizedDescription)") }
        }
        _ = task
        semaphore.wait()
        Darwin.exit(1)
    }

    private static func fail(_ reason: String) {
        FileHandle.standardError.write(Data("启动被阻止：\(reason)\n".utf8))
    }
}
