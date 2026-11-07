import SwiftUI
import AppKit
import GuardianCore

private enum Page: String, CaseIterable {
    case overview = "保护概览"
    case settings = "出口与规则"
    case tests = "保护测试"
    case activity = "事件记录"

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .settings: return "slider.horizontal.3"
        case .tests: return "checkmark.shield"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

struct GuardianView: View {
    @ObservedObject var model: GuardianModel
    @State private var page: Page = .overview
    @State private var draft: GuardianSettings
    @State private var confirmEnable = false
    @State private var confirmPause = false
    @State private var confirmRealTest = false
    private let accent = Color(red: 0.13, green: 0.37, blue: 0.78)

    private var mascot: NSImage {
        if let url = Bundle.main.url(forResource: "GuardianMascot", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        return NSApplication.shared.applicationIconImage
    }

    init(model: GuardianModel) {
        self.model = model
        _draft = State(initialValue: model.state.settings)
    }

    private var statusColor: Color {
        if model.state.lockedReason != nil { return .red }
        if !model.state.enabled { return accent }
        return model.decision.mayLaunch ? .green : .orange
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(page.rawValue).font(.system(size: 26, weight: .semibold))
                        Text(subtitle).foregroundStyle(.secondary).font(.system(size: 13))
                    }
                    Spacer()
                    if page == .overview {
                        if model.checking { ProgressView().controlSize(.small) }
                        Button { model.recheck() } label: {
                            Label("立即检查", systemImage: "arrow.clockwise")
                        }.disabled(model.checking)
                    }
                }.padding(28)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error = model.savingError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red).padding().frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        switch page {
                        case .overview: overview
                        case .settings: settings
                        case .tests: tests
                        case .activity: activity
                        }
                    }.padding(28)
                }
                Divider()
                HStack {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(model.statusTitle)
                    Spacer()
                    Text("本机检查约 2 秒 · 出口检查约 10 秒")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 12)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .alert("启用保护与自动急停？", isPresented: $confirmEnable) {
            Button("取消", role: .cancel) {}
            Button("启用保护") { model.enableProtection() }
        } message: {
            Text("确认异常后会终止当前用户选中的 Claude 进程，包括从其他入口启动的进程。正在生成的回答或执行中的任务可能中断。网络超时只告警。")
        }
        .alert("暂停保护？", isPresented: $confirmPause) {
            Button("取消", role: .cancel) {}
            Button("暂停保护", role: .destructive) { model.pauseProtection() }
        } message: { Text("暂停后不再执行急停，现有 Claude 会继续运行。已有锁定不会被清除。") }
        .alert("真实测试会关闭 Claude", isPresented: $confirmRealTest) {
            Button("取消", role: .cancel) {}
            Button("确认急停并锁定", role: .destructive) { model.realStopTest() }
        } message: {
            Text("会终止当前用户选中的 Claude Desktop / Code 进程，并持续阻止其运行，直到检查通过并手动解锁。请先保存工作。")
        }
        .alert("Account Guardian", isPresented: Binding(get: { !model.notice.isEmpty }, set: { if !$0 { model.notice = "" } })) {
            Button("知道了") { model.notice = "" }
        } message: { Text(model.notice) }
    }

    private var subtitle: String {
        switch page {
        case .overview: return "为 Claude 的每次启动与持续运行检查代理环境。"
        case .settings: return "参考地区检查规则，可额外固定一个出口 IP。"
        case .tests: return "先安全演练，再按需验证真实急停。"
        case .activity: return "查看检测变化、锁定原因与恢复操作。"
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 11) {
                Image(nsImage: mascot).resizable().interpolation(.high)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ACCOUNT").font(.system(size: 10, weight: .bold)).tracking(2)
                    Text("Guardian").font(.system(size: 21, weight: .semibold))
                }
            }.padding(.top, 12)
            VStack(spacing: 7) {
                ForEach(Page.allCases, id: \.self) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .foregroundStyle(page == item ? accent : Color.primary)
                            .background(page == item ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("系统网络检测", systemImage: "network").font(.system(size: 12, weight: .medium))
                Text("macOS · 隧道 / HTTPS 代理").font(.system(size: 11)).foregroundStyle(.secondary)
                Divider().padding(.vertical, 4)
                Text("关闭窗口后仍在菜单栏运行。\n退出应用会停止保护。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            }
        }.padding(20).frame(width: 184).frame(maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private var overview: some View {
        Group {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 15) {
                    if model.state.lockedReason != nil {
                        Image(systemName: "lock.shield.fill").font(.system(size: 38)).foregroundStyle(statusColor)
                    } else {
                        Image(nsImage: mascot).resizable().interpolation(.high)
                            .frame(width: 58, height: 58)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text(model.statusTitle).font(.system(size: 27, weight: .semibold))
                        Text(model.statusDetail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(model.state.enabled ? "ACTIVE" : "OBSERVE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(statusColor.opacity(0.10), in: Capsule()).foregroundStyle(statusColor)
                }
                HStack(spacing: 12) {
                    if model.state.enabled {
                        Button("暂停保护") { confirmPause = true }
                    } else {
                        Button("启用保护") { confirmEnable = true }.buttonStyle(.borderedProminent)
                    }
                    if model.state.lockedReason != nil {
                        Button("重新检查并解锁") { model.recover() }
                            .disabled(!model.state.enabled || model.checking || model.stopping)
                    }
                    if model.stopping { ProgressView().controlSize(.small); Text("正在急停…").font(.caption) }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(statusColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(statusColor.opacity(0.18), lineWidth: 1))

            HStack(alignment: .top, spacing: 16) {
                card("代理与隧道", icon: "network") {
                    Text(model.local.summary).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(model.networkGuidance)
                        .font(.caption).foregroundStyle(.secondary)
                }
                card("当前出口", icon: "globe.asia.australia") {
                    if let observation = model.currentObservation {
                        Text(observation.ip).font(.system(size: 17, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        Text("地区 \(observation.country)  /  目标 \(model.state.settings.country)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("暂时无法确认").font(.system(size: 16, weight: .medium))
                        Text("网络超时不会关闭正在运行的 Claude。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let checked = model.lastChecked {
                        Text("最近检查 \(checked.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            card("受保护的启动", icon: "play.shield") {
                HStack(spacing: 12) {
                    Button { model.launchDesktop() } label: { Label("启动 Claude Desktop", systemImage: "macwindow") }
                        .disabled(!model.state.enabled || model.state.lockedReason != nil || !model.state.settings.protectDesktop || model.checking)
                    Button { model.launchCLI() } label: { Label("启动 Claude Code", systemImage: "terminal") }
                        .disabled(!model.state.enabled || model.state.lockedReason != nil || !model.state.settings.protectCLI || model.checking)
                }
                Text("已识别 \(model.targetCount.map(String.init) ?? "未知数量的") 个受保护进程。每次启动前重新检查，终端执行前再次校验。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Label("进程级保护存在检测窗口；出口探针不代表所有域名或 IPv6 路径都已验证。", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settings: some View {
        Group {
            card("目标地区", icon: "globe") {
                HStack {
                    Text("国家 / 地区代码").frame(width: 125, alignment: .leading)
                    TextField("JP", text: $draft.country).textFieldStyle(.roundedBorder).frame(width: 80)
                        .onChange(of: draft.country) { draft.country = $0.uppercased() }
                    Menu("常用地区") {
                        ForEach(["JP", "US", "SG", "GB", "DE", "CA", "AU", "KR", "TW"], id: \.self) { code in
                            Button(code) { draft.country = code }
                        }
                    }.frame(width: 110)
                }
                Text("与参考项目一致：使用 Cloudflare trace 返回的地区。地区定位可能有误差，不代表 Claude 的地区判断。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card("网络路径自动识别", icon: "network") {
                Text("支持将系统流量接入隧道的 VPN / TUN，以及 macOS 静态 HTTPS 代理。无需选择客户端或填写其配置路径。")
                    .font(.system(size: 13))
                Text("PAC、仅 SOCKS 和无法确认的配置会阻止新的受管启动。系统代理模式下，Claude Code 需从本应用启动以继承检测到的代理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card("指定出口 IP", icon: "pin") {
                Toggle("启用严格 IP 匹配", isOn: $draft.pinEnabled)
                HStack {
                    TextField("例如 203.0.113.10（请填写你的实际公网 IP）", text: $draft.pinnedIP)
                        .textFieldStyle(.roundedBorder).disabled(!draft.pinEnabled)
                    Button("使用当前出口") {
                        if let observation = model.currentObservation {
                            draft.pinnedIP = observation.ip
                            draft.pinEnabled = true
                        }
                    }.disabled(model.currentObservation == nil || Date().timeIntervalSince(model.currentObservation?.timestamp ?? .distantPast) > 25)
                }
                Text("留在未启用状态时，同地区 IP 变化只提醒。启用后地址必须一致，自动检测不会覆盖这里的设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card("保护对象", icon: "app.badge.checkmark") {
                Toggle("Claude Desktop", isOn: $draft.protectDesktop)
                Toggle("Claude Code", isOn: $draft.protectCLI)
                Text("仅处理当前用户匹配到的 Claude 进程。锁定期间从其他入口启动，也会在巡检后终止。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("保存并重新检查") { model.saveSettings(draft) }.buttonStyle(.borderedProminent)
                    .disabled(draft.validationError != nil || model.stopping)
                if let error = draft.validationError { Text(error).font(.caption).foregroundStyle(.orange) }
                Spacer()
            }
            Text("修改规则不会解除已有锁定。启动或解锁时若无法确认出口，门禁保持关闭。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tests: some View {
        Group {
            card("安全模拟演练", icon: "testtube.2") {
                Text("使用独立的模拟状态，验证与真实保护相同的判定逻辑。不会关闭任何进程，也不会更改真实锁定。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(["网络超时", "地区漂移", "IP 不匹配", "代理退出"], id: \.self) { scenario in
                        Button { model.simulate(scenario) } label: {
                            Label(scenario, systemImage: "play.circle").frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                    }
                }
                if !model.simulationOutput.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.simulationOutput.enumerated()), id: \.offset) { entry in
                            Text(entry.element).font(.system(size: 12, design: .monospaced))
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            card("真实急停测试", icon: "exclamationmark.shield") {
                Text("关闭选中的真实 Claude 进程并进入锁定。用于验证进程识别、终止权限和手动恢复，不验证真实网络故障。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button("测试真实急停…", role: .destructive) { confirmRealTest = true }
                    .disabled(!model.state.enabled || model.stopping)
                if !model.state.enabled { Text("先在保护概览中启用保护。").font(.caption).foregroundStyle(.secondary) }
            }
            card("手动验收顺序", icon: "list.number") {
                Text("1. 先演练网络超时，确认结果为保留运行。\n2. 演练地区漂移与 IP 不匹配，确认锁定保持。\n3. 保存工作后执行真实急停测试。\n4. 返回概览，检查并解锁，再通过门禁启动。")
                    .font(.system(size: 13)).lineSpacing(7)
            }
        }
    }

    private var activity: some View {
        card("最近 200 条事件", icon: "clock") {
            ForEach(model.events) { event in
                HStack(alignment: .top, spacing: 18) {
                    Text(event.time.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                    Text(event.text).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.padding(.vertical, 6)
                if event.id != model.events.last?.id { Divider() }
            }
        }
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
            content()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}
