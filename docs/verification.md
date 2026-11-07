# 第一版验证记录

验证日期：2026-11-07。本机 macOS，Clash Party 2.0.4。

## 已完成

- `swift test --disable-sandbox`：19 项 XCTest 全部通过，无跳过或失败。
- 自动急停测试仅创建并终止自己的 `/bin/sleep` 子进程，并验证过期进程身份不会被终止。
- `guardian-diagnostics --network`：识别 Party 内核在线、实际路由使用 utun1500、发现当前用户的 Claude 进程、发现 Claude Code 命令；Cloudflare 返回有效 JP 地区。未输出公网 IP。
- release 构建、`.app` 打包、图标生成、本地 ad-hoc 签名成功。
- 实际打开打包应用，验证主窗口、出口设置和观察模式。
- 在实际界面逐项点击网络超时、地区漂移、IP 不匹配、代理退出模拟，结果符合规则；真实急停按钮在观察模式下禁用。
- 发现并修复 macOS `ps` 列对齐空白导致的路径匹配错误，并添加对应回归输入。

## 尚未执行的破坏性验收

未终止用户正在使用的 Claude，未关闭 Clash Party、TUN 或网络，未执行真实节点切换。真实 Claude 急停、受管启动和网络故障端到端验收，需在用户保存工作后按 docs/testing.md 操作。

模拟和临时进程测试证明规则及终止机制工作，不等于验证所有真实代理分流、IPv6 路径或 Claude 子进程。应用当前留在观察模式。
