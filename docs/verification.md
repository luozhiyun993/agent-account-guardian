# 验证记录

## 0.2.2 图标来源统一（2026-11-07）

- 移除主界面出现时对 `NSApplication.applicationIconImage` 的动态覆盖；Dock 图标统一由应用包的 `CFBundleIconFile` 提供，侧栏插画仍从同一渲染器生成。
- 构建改用全新的临时应用包，签名并验证成功后替换旧包。确认最终 Resources 仅包含 `GuardianSafe.icns` 和 `GuardianMascot.png`，不再夹带旧 `Guardian.icns`。
- 从 macOS `NSWorkspace.icon(forFile:)` 读取打包应用的默认图标并目视确认是小锁。解包 ICNS 检查 10 个尺寸：8 个像素完全相同，16/32 像素的非 Retina 编码有轻微差异，平均通道差异均小于 1/255。
- release 构建、严格签名校验和脚本语法检查通过。刷新此应用的 Launch Services 注册；未重启当前守护或 Dock，未实时观察用户当前旧进程的退出动画。

## 0.2.1 Dock 窗口恢复（2026-11-07）

- 增加应用重新打开事件处理，通过 SwiftUI 的主窗口标识恢复窗口；菜单栏持续监控逻辑不变。
- 独立 SwiftUI 验证程序复用同一 delegate 和窗口修饰器，包含常驻菜单栏。通过系统打开应用请求触发 reopen，连续两次关闭后恢复、一次最小化后恢复均通过，每次仅有一个可见主窗口。
- 验证程序不加载 GuardianModel，不读取保护状态，不启动或终止 Claude。未中断当前守护；未对实际 Dock 进行人工点击验收。
- 0.2.1（build 5）release 构建完成，打包应用通过严格签名校验。

## 0.2 通用代理检测（2026-11-07）

- 30 项 XCTest 全部通过，无跳过或失败；包括不同隧道名称、无关虚拟网卡、部分直连路由、路由缺失、静态 HTTPS 代理、PAC/SOCKS 等未知模式、按网卡配置冲突、绕过规则、CLI 环境清理及路径切换。
- 本地临时 TCP 代理集成测试实际收到 Cloudflare HTTPS CONNECT；返回 403 后出口检测保持未知，没有取得直连出口结果。测试不修改系统代理。
- 自动急停测试只终止自身创建的 `/bin/sleep` 子进程，不终止真实 Claude。
- 只读真实诊断：不读取任何代理客户端配置，识别系统隧道 utun1500，Cloudflare 出口地区 JP；公网地址默认隐藏。未更改保护状态。
- 0.2.0（build 4）release 打包与 ad-hoc 签名完成，`codesign --verify --deep --strict` 通过。保留正在启用保护的旧进程，新包下次重开生效；本轮未做新版 GUI 交互验收。
- 未逐一安装或验收其他品牌代理客户端；支持范围按 README 中的系统网络模式界定。真实 Claude 经系统 HTTPS 代理启动、切换客户端及断网急停仍按 docs/testing.md 手工验收。

## 0.1 初版历史记录

验证日期：2026-11-07。本机 macOS，Clash Party 2.0.4。

### 已完成

- `swift test --disable-sandbox`：19 项 XCTest 全部通过，无跳过或失败。
- 自动急停测试仅创建并终止自己的 `/bin/sleep` 子进程，并验证过期进程身份不会被终止。
- `guardian-diagnostics --network`：识别 Party 内核在线、实际路由使用 utun1500、发现当前用户的 Claude 进程、发现 Claude Code 命令；Cloudflare 返回有效 JP 地区。未输出公网 IP。
- release 构建、`.app` 打包、图标生成、本地 ad-hoc 签名成功。
- 实际打开打包应用，验证主窗口、出口设置和观察模式。
- 在实际界面逐项点击网络超时、地区漂移、IP 不匹配、代理退出模拟，结果符合规则；真实急停按钮在观察模式下禁用。
- 发现并修复 macOS `ps` 列对齐空白导致的路径匹配错误，并添加对应回归输入。

### 尚未执行的破坏性验收

未终止用户正在使用的 Claude，未关闭 Clash Party、TUN 或网络，未执行真实节点切换。真实 Claude 急停、受管启动和网络故障端到端验收，需在用户保存工作后按 docs/testing.md 操作。

模拟和临时进程测试证明规则及终止机制工作，不等于验证所有真实代理分流、IPv6 路径或 Claude 子进程。应用当前留在观察模式。
