# Account Guardian

[简体中文](README.md) · [English](README.en.md)

<img src="assets/icon.png" width="128" alt="Account Guardian 小锁卫士图标">

一个面向 macOS、不绑定代理客户端的 Claude 代理守护桌面应用。包含启动前门禁、持续检测、进程急停、异常锁定和手动恢复。

## 功能

- 原生 SwiftUI 主窗口与菜单栏，搭配简笔画小锁图标。
- 自动识别系统静态 HTTPS 代理或实际隧道路由。
- 网络状态与进程检查状态独立展示、分别记录；进程读取失败不会覆盖网络结果，仍会阻止受管启动和解锁。
- 出口地区匹配，以及可选的手动指定出口 IP。
- Claude Desktop / Code 启动门禁、持续监控、异常急停与持久锁定。
- 网络超时保留正在运行的 Claude；手动重新检查通过后才能解锁。
- 安全故障模拟、真实急停测试、只读诊断工具和本地事件记录。

## 运行

需要 macOS 13 或更高版本、Swift 5.9 或更高版本的开发工具，以及提供系统隧道或 macOS 静态 HTTPS 代理的网络工具。无第三方包依赖。在项目根目录运行：

```sh
bash scripts/build-app.sh
open "dist/Account Guardian.app"
```

也可以运行 `swift run AccountGuardian` 开发调试。发布包使用本机 ad-hoc 签名，未公证；打包脚本同时构建 arm64 和 x86_64，生成 Apple Silicon / Intel 双架构应用。

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
| 系统 HTTPS 代理端口明确拒绝连接 | 急停并锁定 | 阻止 |
| 无系统 HTTPS 代理，且完整探测路由包含非隧道路径 | 急停并锁定 | 阻止 |
| 保护期间切换系统代理端点或代理/隧道模式 | 急停并锁定，避免进程继续使用旧代理 | 阻止 |
| 网络不通、出口查询超时或结果不可信 | 保持运行，显示未知并重试 | 阻止 |
| 无法读取进程、路由或配置 | 保持运行，显示未知并重试 | 阻止 |

指定 IP 是可选的附加限制，不覆盖目标地区要求。「使用当前出口」只填入待保存设置，需要点击保存。自动检测永远不会更新用户固定的 IP 或目标地区。

本机检查约每 2 秒一次，出口查询在上次结束后约 10 秒再次执行；网络请求有最多约 10 秒的超时，系统调度和命令执行还会增加延迟。网络探针独立于本机巡检，网络超时不会阻塞本机异常检查。锁定保持到用户重新检查并解锁；更改设置、暂停保护或重开应用不会清除锁定。

## 通用网络检测

- 不读取客户端进程、安装路径、订阅或配置文件，也不需要 external-controller。
- 优先读取 macOS 静态 HTTPS 代理，验证端口可连接，并让出口探针显式使用同一个代理；代理拒绝请求不会回退直连。
- 没有系统代理时，核对 `1.1.1.1` 和 `8.8.8.8` 的实际路由都经过现存的 `utun`、`tun`、`ppp`、`ipsec` 或 `wg` 隧道。仅存在虚拟网卡不代表检测通过。
- PAC / 自动代理、仅 SOCKS、仅 HTTP、冲突的按网卡设置，以及无法确认的绕过规则显示「未知」。IP / 网段例外与非 `.local` 通配例外采用保守阻止策略。不能仅凭客户端品牌推断支持；请使用可确认的系统 HTTPS 代理或隧道配置。
- 路由暂缺、网卡切换或代理连接超时只等待重试，不因检测不到信息急停；明确非隧道路由或端口拒绝连接才触发本机异常。
- 通过所选路径访问 `https://www.cloudflare.com/cdn-cgi/trace`，读取 `ip` 和 `loc`。路径变化会废弃旧出口结果，重新检测。
- 系统代理模式下，请通过本应用启动 Claude Code：启动器会设置代理环境变量并清除旧的代理和绕过变量。外部终端启动的 CLI 可能忽略系统代理，无法保证与探针路径一致。桌面应用仍依赖自身遵循系统代理；自定义应用代理或分流规则需自行验证。

## 保护对象与启动

进程身份优先使用 `proc_pidpath` 返回的真实路径；该接口失败时，使用 `KERN_PROCARGS2` 中内核保存的可执行路径作为备用，不使用可改写的 `argv[0]` 或 `ps` 显示名授权终止。仅匹配当前用户动态发现的 Claude Desktop 应用与 Claude Code 安装入口。其他软件的 Node / Bun 不会仅因名称进入候选；npm 方式必须匹配 Claude Code 的实际脚本入口。已退出或僵尸候选不阻断检查。

无法核实的真实 Claude 候选会单独提示并阻止新的受管启动/解锁，但不会丢弃已核实的目标。网络异常急停时仍终止已核实的 Claude 进程；无法核实的目标不会凭名称误杀。

可分别选择 Claude Desktop 与 Claude Code。Desktop 通过产品 Bundle ID、系统应用注册和运行进程的外层应用元数据发现，不要求固定目录或文件名；监测与启动复用发现结果。CLI 搜索当前 PATH、常见原生/Homebrew/npm 安装、nvm/asdf/mise/fnm/Volta 入口，并保留原生版本目录中的多个版本。npm 模式根据 `package.json` 的产品名称和 `bin.claude` 声明定位脚本，不依赖 `cli.js` 文件名；支持常见 Node 前置参数及进程工作目录下的相对脚本路径。

特殊 shell 别名、无法解析的 shim 或未覆盖的安装器，可以在「出口与规则 → 安装位置」填写可信的 `.app` / CLI 命令绝对路径（或 `~/`），留空使用自动发现。产品 Bundle ID、npm 包名称和有限的安装器布局仍是匹配约定，不是任意进程的签名认证；纯 shell shim 不作为终止目标。macOS 权限限制、未知 Node 参数等仍可能造成漏检，不能保证所有自定义运行方式；可运行 `guardian-diagnostics --list-installations --list-processes` 核对。

Claude Desktop 通过系统应用启动接口打开。Claude Code 在 Terminal 中启动，执行前会再次检查保护应用心跳、锁定状态、设置、代理和出口。CLI 初始工作目录由 Terminal 决定，需要项目上下文时可在终端中切换目录后使用应用生成的受管命令：

```sh
"/你的路径/Account Guardian.app/Contents/MacOS/AccountGuardian" --guarded-cli
```

锁定且保护开启期间，从其他入口启动的匹配进程也会在巡检后终止。直接启动 Claude 无法享受启动前门禁；原始 CLI 命令依然存在。急停先发送 TERM，等待后对仍匹配原身份的进程发送 KILL，可能中断未完成的工作。

## 测试

需要核对已识别的 PID 和本机可执行路径时，可运行 `swift run guardian-diagnostics --list-processes`。它不会终止进程，也不会输出会话参数。

```sh
swift test --disable-sandbox
bash scripts/verify-discovery.sh
swift run guardian-diagnostics --list-installations
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

设计参考 [YOURSJEYO/claude-switcher](https://github.com/YOURSJEYO/claude-switcher) 的启动检查与进程急停思路，本项目独立使用 Swift / SwiftUI 实现。不是原项目的完整移植，也不构成账号不受限制的保证。
