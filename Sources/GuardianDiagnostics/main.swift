import Foundation
import GuardianCore

let connection = LocalInspector.inspectConnection()
print("代理与路由：\(connection.health.summary)")
let settings = (try? StateStore().load().settings) ?? GuardianSettings()
let inspection = ProcessInspector.inspect(settings: settings)
print("进程检查：\(inspection.health.summary)")
if CommandLine.arguments.contains("--list-processes") {
    for target in inspection.targets {
        print("已识别 PID \(target.pid)：\(target.executable)")
    }
}
let installations = InstallationDiscovery.discover(settings: settings)
print("安装发现：Desktop \(installations.desktopApplications.count) 处 · CLI 命令 \(installations.cliCommands.count) 个 · 原生文件 \(installations.nativeExecutables.count) 个")
if CommandLine.arguments.contains("--list-installations") {
    for app in installations.desktopApplications { print("Desktop 安装：\(app.path)") }
    for command in installations.cliCommands { print("CLI 入口：\(command.path)") }
}
print("Claude Code：\(installations.cliCommands.isEmpty ? "未找到" : "已找到")")
if CommandLine.arguments.contains("--network") {
    let result: ExitHealth
    if let transport = connection.transport {
        result = await ExitInspector.inspect(transport: transport)
    } else {
        result = .unknown("没有可确认的代理或隧道路径，未发送出口请求。")
    }
    switch result {
    case .known(let observation):
        print("出口探针：有效；地区 \(observation.country)；地址默认隐藏")
        if CommandLine.arguments.contains("--show-ip") { print("出口 IP：\(observation.ip)") }
    case .unknown(let reason): print("出口探针：\(reason)")
    }
} else {
    print("未发送网络探测；使用 --network 启用 Cloudflare 出口查询。")
}
print("诊断结束：未启动或终止任何 Claude 进程，未更改保护状态。")
