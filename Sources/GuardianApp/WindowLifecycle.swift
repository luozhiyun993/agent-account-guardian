import AppKit
import SwiftUI

@MainActor
final class GuardianAppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let openMainWindow else { return true }
        openMainWindow()
        sender.activate(ignoringOtherApps: true)
        return false
    }
}

struct MainWindowReopenHandler: ViewModifier {
    let delegate: GuardianAppDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.openMainWindow = { openWindow(id: "main") }
        }
    }
}
