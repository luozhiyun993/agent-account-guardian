# Account Guardian

[简体中文](README.md) · [English](README.en.md)

<img src="assets/icon.png" width="128" alt="Account Guardian 小锁卫士图标">

一个面向 macOS、适配 Clash Party 的 Claude 代理守护桌面应用。包含启动前门禁、持续检测、进程急停、异常锁定和手动恢复。

## 功能

- 原生 SwiftUI 主窗口与菜单栏，搭配简笔画小锁图标。
- 检查 Clash Party 内核、TUN 和探测路由。
- 出口地区匹配，以及可选的手动指定出口 IP。
- Claude Desktop / Code 启动门禁、持续监控、异常急停与持久锁定。
- 网络超时保留正在运行的 Claude；手动重新检查通过后才能解锁。
- 安全故障模拟、真实急停测试、只读诊断工具和本地事件记录。

## 运行

需要 macOS 13 或更高版本、Swift 5.9 或更高版本的开发工具，以及已安装并开启 TUN 的 Clash Party。无第三方包依赖。在项目根目录运行：

```sh
bash scripts/build-app.sh
open "dist/Account Guardian.app"
```

也可以运行 `swift run AccountGuardian` 开发调试。发布包使用本机 ad-hoc 签名，未公证；当前构建产物面向本机架构。

首次打开处于**观察模式**：会检查环境，但不会终止任何 Claude 进程。先进入「出口与规则」，确认目标国家代码及可选的固定 IP，再在「保护概览」启用保护。

「立即检查」仅位于「保护概览」，用于刷新真实环境。测试页的四种模拟不改变真实保护状态。

关闭主窗口后，应用仍在菜单栏运行。退出应用会停止监控和急停；重开默认回到观察模式，已有锁定保留。当前版本不安装系统守护服务、不配置开机启动。

## 保护规则

| 情况 | 正在运行的 Claude | 从本应用启动 / 手动解锁 |
| --- | --- | --- |
| 代理和出口检查通过 | 保持运行 | 允许，已有锁定仍需手动解锁 |
| 同地区内 IP 变化，未启用指定 IP | 提醒并保持运行 | 允许 |
| 出口地区不符合设置 | 急停并锁定 | 阻止 |
| 已启用指定 IP，出口不一致 | 急停并锁定 | 阻止 |
| 确认 Party 内核退出、TUN 关闭或目标网卡消失 | 急停并锁定 | 阻止 |
| 探测路由明确离开目标 TUN | 急停并锁定 | 阻止 |
| 网络不通、出口查询超时或结果不可信 | 保持运行，显示未知并重试 | 阻止 |
| 无法读取进程、路由或配置 | 保持运行，显示未知并重试 | 阻止 |

指定 IP 是可选的附加限制，不覆盖目标地区要求。「使用当前出口」只填入待保存设置，需要点击保存。自动检测永远不会更新用户固定的 IP 或目标地区。

本机检查约每 2 秒一次，出口查询在上次结束后约 10 秒再次执行；网络请求有最多约 10 秒的超时，系统调度和命令执行还会增加延迟。网络探针独立于本机巡检，网络超时不会阻塞本机异常检查。锁定保持到用户重新检查并解锁；更改设置、暂停保护或重开应用不会清除锁定。

## Clash Party 适配

- 识别 `/Applications/Clash Party.app` 或用户 `Applications` 中随应用分发的 `sidecar/mihomo`、`mihomo-alpha`、`mihomo-smart` 内核。
- 从 `~/Library/Application Support/mihomo-party/mihomo.yaml` 提取 TUN 开关及设备名，不展示或存储配置中的订阅及控制器密钥。
- 核对指定设备确实存在，并核对 `1.1.1.1` 和 `8.8.8.8` 的系统路由使用该设备。
- 当前适配要求 TUN 模式，不要求打开 external-controller，也不会修改 Party 的代理配置。
- 从正常系统网络路径访问 `https://www.cloudflare.com/cdn-cgi/trace`，取 `ip` 和 `loc`。不显式指定代理，避免测试路径与桌面程序默认路径脱节。

## 保护对象与启动

可分别选择 Claude Desktop 与 Claude Code。桌面进程限定当前用户和已知 `Claude.app/Contents/` 路径；CLI 根据已安装命令解析出的实际可执行文件识别，也支持常见 npm 的 `node/bun + @anthropic-ai/claude-code/cli.js` 入口。未发现的自定义安装路径或额外 Node 参数不承诺覆盖，请先查看进程数量或运行诊断工具。

Claude Desktop 通过系统应用启动接口打开。Claude Code 在 Terminal 中启动，执行前会再次检查保护应用心跳、锁定状态、设置、代理和出口。CLI 初始工作目录由 Terminal 决定，需要项目上下文时可在终端中切换目录后使用应用生成的受管命令：

```sh
"/你的路径/Account Guardian.app/Contents/MacOS/AccountGuardian" --guarded-cli
```

锁定且保护开启期间，从其他入口启动的匹配进程也会在巡检后终止。直接启动 Claude 无法享受启动前门禁；原始 CLI 命令依然存在。急停先发送 TERM，等待后对仍匹配原身份的进程发送 KILL，可能中断未完成的工作。

## 测试

```sh
swift test --disable-sandbox
swift run guardian-diagnostics
swift run guardian-diagnostics --network
```

自动测试覆盖地区/IP 规则、网络未知策略、持久锁定、手动恢复、过期观测、进程匹配与身份复核。真实终止的自动测试只针对测试创建的 `/bin/sleep` 子进程。

诊断命令不会启动或终止 Claude，不写入保护状态；默认不发网络请求，加 `--network` 才查询 Cloudflare。公网 IP 默认不输出，如需查看可加 `--show-ip`。

界面「保护测试」提供两层验证：

1. **安全模拟**：代理退出、地区漂移、IP 不匹配、网络超时。使用同一判定与锁定模型，但隔离真实设置和进程。不能替代真实网络验证。
2. **真实急停**：启用保护后，明确确认才终止选中的真实 Claude 并锁定。请先保存工作；测试后在概览重新检查并解锁。

更完整的验收步骤见 [docs/testing.md](docs/testing.md)。

## 项目结构

```text
Sources/GuardianCore/          检测、进程识别、规则与状态持久化
Sources/GuardianApp/           SwiftUI 界面、监控与受管启动
Sources/GuardianDiagnostics/   只读诊断命令
Tests/GuardianCoreTests/       规则和进程终止测试
scripts/                      应用打包与各尺寸图标绘制
packaging/                    macOS 应用元数据
assets/                       README 图标
docs/                         需求、测试步骤与验证记录
```

源码仓库不包含 `.build/`、`dist/`、个人保护配置或运行日志；按构建命令可在本机生成应用。

## 数据与边界

设置和锁定存于 `~/Library/Application Support/AgentAccountGuardian/state.json`，事件存于同目录的 `events.json`，最多保留 200 条。目录权限 0700，文件 0600。设置包含预期 IP 和上次检测 IP；事件不记录账号凭据、订阅 URL 或完整进程参数。当前应用不读取 Claude 密码、Cookie 或 Keychain。

这是进程级急停，不是防火墙。检测到终止之间存在时间窗口；应用未运行、被强制退出或系统睡眠时无法保护。允许网络未知时继续运行也是明确的可用性取舍，不能据此宣称故障时绝不直连。

Cloudflare 的出口地区可能与服务商判断不同。一次探针只证明该次请求的路径；两个路由探测不证明所有 Claude 域名都正确分流。当前不完整验证 DNS、STUN/WebRTC、IPv6 旁路、所有代理规则，也不实现参考项目的账号切换、设备指纹调整、时区修改或 root 守护。固定 IP 检查同样不能替代完整网络隔离。

## 致谢

设计参考 [YOURSJEYO/claude-switcher](https://github.com/YOURSJEYO/claude-switcher) 的启动检查与进程急停思路，本项目独立使用 Swift / SwiftUI 实现，并针对 Clash Party 适配。不是原项目的完整移植，也不构成账号不受限制的保证。
