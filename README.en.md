# Account Guardian

[简体中文](README.md) · [English](README.en.md)

<img src="assets/icon.png" width="128" alt="Account Guardian friendly padlock icon">

A native macOS desktop app that checks the proxy environment used by Claude, with Clash Party integration. It provides launch checks, continuous monitoring, process termination on confirmed faults, persistent lockout, and manual recovery.

## Features

- Native SwiftUI window and menu bar, with a friendly illustrated padlock icon.
- Clash Party core, TUN interface, and probe-route checks.
- Exit-country validation and optional manually pinned exit IP.
- Protected launching and monitoring for Claude Desktop and Claude Code.
- Confirmed faults terminate selected processes and lock protection until manual recovery.
- Network timeouts leave existing Claude processes running while blocking new managed launches.
- Isolated fault simulations, an explicitly confirmed real emergency-stop test, a read-only diagnostic tool, and local event history.

The current interface is in Simplified Chinese. This English README documents the same behavior.

## Build and run

Requires macOS 13 or later, Swift 5.9 or later, and Clash Party with TUN enabled. There are no third-party package dependencies. From the project root:

```sh
bash scripts/build-app.sh
open "dist/Account Guardian.app"
```

For development, use `swift run AccountGuardian`. The packaged app is ad-hoc signed locally, is not notarized, and targets the architecture of the build machine.

The app starts in **observation mode**: it checks the environment without terminating Claude. In **Exit & Rules (出口与规则)**, confirm the target country code and optional pinned IP, save your settings, then enable protection from **Overview (保护概览)**.

**Check Now (立即检查)** appears only on Overview and refreshes the real environment. The four simulations on the test page do not change live protection state.

Closing the window leaves the menu bar app running. Quitting stops monitoring and process enforcement. Reopening returns to observation mode while retaining any existing lockout. This version does not install a system daemon or enable launch at login.

## Protection rules

| Condition | Existing Claude processes | Managed launch / manual unlock |
| --- | --- | --- |
| Local proxy and exit checks pass | Keep running | Allowed; an existing lock still requires manual recovery |
| IP changes within the target country, without IP pinning | Warn and keep running | Allowed |
| Exit country does not match | Terminate and lock | Blocked |
| IP pinning is enabled and the address does not match | Terminate and lock | Blocked |
| Party core has exited, TUN is disabled, or the configured interface disappears | Terminate and lock | Blocked |
| A probe route is confirmed to have left the configured TUN | Terminate and lock | Blocked |
| Network unavailable, exit lookup timeout, or unusable response | Keep running, show unknown, retry | Blocked |
| Process, route, or configuration inspection is unavailable | Keep running, show unknown, retry | Blocked |

IP pinning is an additional restriction; it does not override the target country. **Use Current Exit (使用当前出口)** fills the draft setting, which must then be saved. Automatic checks never change the configured country or pinned IP.

Local checks run approximately every 2 seconds. Exit checks repeat approximately 10 seconds after the previous request finishes; requests have a timeout of approximately 10 seconds. Command execution and system scheduling add latency. Network and local monitoring run independently so a slow exit lookup does not block local checks.

A lock remains until the user requests recovery and fresh checks pass. Changing settings, pausing protection, or reopening the app does not clear it.

## Clash Party integration

- Recognizes the bundled `sidecar/mihomo`, `mihomo-alpha`, or `mihomo-smart` core inside `/Applications/Clash Party.app` or the user's `Applications` directory.
- Extracts the TUN enabled flag and device name from `~/Library/Application Support/mihomo-party/mihomo.yaml`. Subscription details and controller secrets are not displayed or persisted.
- Confirms that the configured interface exists and that system routes to `1.1.1.1` and `8.8.8.8` use it.
- Requires TUN mode. An external controller is not required, and the app does not modify Party settings.
- Requests `https://www.cloudflare.com/cdn-cgi/trace` through the normal system network path and reads `ip` and `loc`. The request does not explicitly force a separate proxy path.

## Protected applications and launching

Claude Desktop and Claude Code can be selected independently. Desktop matching is limited to the current user and known `Claude.app/Contents/` paths. CLI matching uses the resolved executable of an installed Claude command and supports common npm entry points using `node` or `bun` with `@anthropic-ai/claude-code/cli.js`.

Custom installation paths or additional Node launch flags may not be recognized. Check the detected process count or use the diagnostics command first.

Desktop launches use the system application API. Claude Code launches in Terminal and checks the guardian heartbeat, lock, settings, local proxy, and exit again immediately before execution. Terminal determines the initial working directory. For a particular project, change directories in Terminal and run:

```sh
"/your/path/Account Guardian.app/Contents/MacOS/AccountGuardian" --guarded-cli
```

While protection is enabled and locked, matching processes launched elsewhere are also terminated after detection. Direct launches bypass the pre-launch gate and the original CLI remains available. Emergency termination sends TERM first, then KILL to remaining processes whose identity still matches. Work in progress may be interrupted.

## Testing

```sh
swift test --disable-sandbox
swift run guardian-diagnostics
swift run guardian-diagnostics --network
```

Tests cover country/IP policy, unknown network states, persistent locks, manual recovery, stale observations, process matching, and identity revalidation. The automated termination test only terminates a disposable `/bin/sleep` child that the test itself created.

Diagnostics do not launch or terminate Claude and do not write protection state. Network requests are disabled by default; `--network` enables the Cloudflare lookup. Public IP output is hidden unless `--show-ip` is also provided.

The **Protection Tests (保护测试)** page offers:

1. **Safe simulation:** core exit, country drift, pinned-IP mismatch, and network timeout. Uses the real policy and lock model with isolated state and no process termination. This does not replace testing actual network failures.
2. **Real emergency-stop test:** after protection is enabled, explicit confirmation terminates the selected real Claude processes and locks protection. Save your work first. Return to Overview to check and unlock afterward.

Additional acceptance steps and verification results are in [docs/testing.md](docs/testing.md) and [docs/verification.md](docs/verification.md), currently in Chinese.

## Project structure

```text
Sources/GuardianCore/          Inspection, process matching, policy, persistence
Sources/GuardianApp/           SwiftUI interface, monitoring, protected launches
Sources/GuardianDiagnostics/   Read-only diagnostic CLI
Tests/GuardianCoreTests/       Policy and process termination tests
scripts/                      App packaging and icon rendering
packaging/                    macOS bundle metadata
assets/                       README icon
docs/                         Requirements, test procedures, verification notes
```

The source repository excludes `.build/`, `dist/`, personal protection settings, and runtime logs. Build the application locally using the commands above.

## Data and limitations

Settings and lock state are stored in `~/Library/Application Support/AgentAccountGuardian/state.json`. Events are stored in `events.json` in the same directory, with up to 200 entries. The directory uses mode 0700 and files use 0600. Settings contain the expected IP and last observed IP; events do not record account credentials, subscription URLs, or complete process arguments. The app does not read Claude passwords, cookies, or Keychain items.

This is process-level protection, not a firewall. Packets may be sent between a fault and process termination. Protection is unavailable when the app is not running, is forcibly stopped, or the system is asleep. Continuing to run during an unknown network state is an intentional availability trade-off, not a guarantee against direct connections.

Cloudflare's country classification may differ from the service provider's. A lookup validates only that request's path, and two route probes do not validate every Claude domain. This version does not comprehensively check DNS, STUN/WebRTC, IPv6 bypass, or all proxy routing rules. It does not implement account switching, fingerprint changes, timezone changes, or a root daemon. IP pinning is not a substitute for network isolation.

## Acknowledgments

The launch-check and emergency-stop ideas were inspired by [YOURSJEYO/claude-switcher](https://github.com/YOURSJEYO/claude-switcher). This is an independent Swift / SwiftUI implementation adapted for Clash Party, not a complete port. It does not guarantee that an account will remain unrestricted.
