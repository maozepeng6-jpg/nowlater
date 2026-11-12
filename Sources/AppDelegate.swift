import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private var notch: NotchController?
    private var isFinishingQuit = false
    private var quitAlert: NSAlert?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        notch = NotchController(store: store)
    }

    @objc func requestQuitConfirmation(_ sender: Any?) {
        guard !isFinishingQuit, quitAlert == nil else { return }
        let alert = QuitConfirmation.makeAlert()
        quitAlert = alert
        let shown = notch?.presentQuitConfirmation(alert) { [weak self] response in
            self?.quitAlert = nil
            if response == .alertFirstButtonReturn { NSApp.terminate(nil) }
        } ?? false
        if !shown { quitAlert = nil }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFinishingQuit else { return .terminateLater }
        isFinishingQuit = true

        // Native todo editors save on resignation. History rows explicitly commit
        // their SwiftUI drafts rather than waiting for focus rendering to catch up.
        for window in sender.windows {
            window.makeFirstResponder(nil)
        }
        NotificationCenter.default.post(name: .nowLaterWillQuit, object: nil)

        // Let already queued editor commits finish before terminating the process.
        DispatchQueue.main.async {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Standard keyboard commands

    /// 没有这个菜单，无 Dock 图标的 app 里 ⌘C / ⌘V / ⌘A 全都不生效
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 NowLater", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 NowLater", action: #selector(requestQuitConfirmation(_:)), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(smartPaste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    /// 刘海面板里多行粘贴 → 批量加条目；其它情况走系统默认粘贴
    @objc func smartPaste(_ sender: Any?) {
        if let notch, notch.trySmartPaste() { return }
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
    }
}
