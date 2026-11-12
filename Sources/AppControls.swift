import SwiftUI
import AppKit

extension Notification.Name {
    static let nowLaterWillQuit = Notification.Name("com.nowlater.app.willQuit")
}

enum QuitConfirmation {
    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "是否确认退出？"
        alert.informativeText = "当前内容会自动保存。"
        alert.addButton(withTitle: "是")
        alert.addButton(withTitle: "取消")
        alert.window.appearance = NSAppearance(named: .darkAqua)
        for button in alert.buttons {
            button.bezelColor = .darkGray
        }
        alert.buttons[1].keyEquivalent = "\u{1b}"
        return alert
    }
}

/// Shared, quiet exit control for both pages inside the notch.
struct QuitButton: View {
    var body: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.requestQuitConfirmation(_:)),
                             to: NSApp.delegate, from: nil)
        } label: {
            Image(systemName: "power")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.50))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("退出 NowLater（⌘Q）")
        .accessibilityLabel("退出 NowLater")
    }
}
