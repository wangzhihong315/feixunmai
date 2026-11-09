import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var deckWindow: VibeDeckWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        BridgeModel.shared.start()
        setupStatusItem()
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        BridgeModel.shared.shutdown()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VibeDeck")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func showMainWindow() {
        if deckWindow == nil {
            deckWindow = VibeDeckWindowController()
        }
        deckWindow?.showWindow(nil)
        deckWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var window: NSWindow? { deckWindow?.window }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let model = BridgeModel.shared
        let phone = PhoneAudioBridge.shared
        let primary = model.voiceSource == .phone
            ? "VibePad：\(phone.stateText)"
            : "遥控器：\(model.connectionState.rawValue)"
        let status = NSMenuItem(
            title: "状态：\(primary)\(model.voiceActive ? "（说话中）" : "")",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开控制台", action: #selector(showPanel), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 VibeDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func showPanel() {
        showMainWindow()
    }
}

@main
final class FeiXunMaiApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
