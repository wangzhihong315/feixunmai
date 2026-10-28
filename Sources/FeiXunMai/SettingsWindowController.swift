import AppKit
import AVFoundation
import CoreAudio

/// 纯 AppKit 设置窗口：NSTabView 原生标签页（单击即切，无 SwiftUI 渲染问题）。
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    private let model = BridgeModel.shared

    private var devicePopup: NSPopUpButton!
    private var voiceKeyPopup: NSPopUpButton!
    private var tapToggle: NSButton!
    private var autoSwitchCheck: NSButton!
    private var monitorCheck: NSButton!
    private var arrowsMouseCheck: NSButton!
    private var statusLabel: NSTextField!
    private var voiceStatusLabel: NSTextField!
    private var lastKeyLabel: NSTextField!
    private var axWarning: NSTextField!
    private var mappingPopups: [MappedButton: NSPopUpButton] = [:]
    private var statLabels: (count: NSTextField, seconds: NSTextField)!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "斐讯麦"
        self.init(window: window)
        window.delegate = self
        if UserDefaults.standard.bool(forKey: "minimalUI") {
            let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 640, height: 540))
            tabView.addTabViewItem(makeTabItem(id: "a", label: "连接与语音", view: NSView()))
            tabView.addTabViewItem(makeTabItem(id: "b", label: "按键映射", view: NSView()))
            tabView.addTabViewItem(makeTabItem(id: "c", label: "统计", view: NSView()))
            tabView.delegate = self
            let vc = NSViewController()
            vc.view = tabView
            window.contentViewController = vc
        } else {
            window.contentViewController = makeTabViewController()
        }
    }

    // MARK: - 标签页

    private func makeTabItem(id: String, label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: id)
        item.label = label
        item.view = view
        return item
    }

    private func makeTabViewController() -> NSViewController {
        let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 640, height: 540))
        tabView.tabViewType = .topTabsBezelBorder
        tabView.addTabViewItem(makeTabItem(id: "conn", label: "连接与语音", view: makeConnectionTab()))
        tabView.addTabViewItem(makeTabItem(id: "keys", label: "按键映射", view: makeKeyMappingTab()))
        tabView.addTabViewItem(makeTabItem(id: "stats", label: "统计", view: makeStatsTab()))
        tabView.delegate = self
        let vc = NSViewController()
        vc.view = tabView
        return vc
    }

    /// 点击→Tab 切换的真实延迟（毫秒），用于客观定位卡顿来源
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        let now = ProcessInfo.processInfo.systemUptime
        let latency = NSApp.currentEvent.map { (now - $0.timestamp) * 1000 } ?? -1
        let appActive = NSApp.isActive ? 1 : 0
        let winKey = window?.isKeyWindow == true ? 1 : 0
        NSLog("斐讯麦[TAB] latency=%.0fms tab=%@ appActive=%d winKey=%d",
              latency, tabViewItem?.label ?? "?", appActive, winKey)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NSLog("斐讯麦[WIN] became key")
    }

    func windowDidResignKey(_ notification: Notification) {
        NSLog("斐讯麦[WIN] resigned key")
    }

    // MARK: - Tab 1 连接与语音

    private func makeConnectionTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        statusLabel = label("遥控器：…", size: 14, weight: .semibold)
        voiceStatusLabel = label("语音：待机", size: 12)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(voiceStatusLabel)

        addSeparator(to: stack, title: "声音路由")

        autoSwitchCheck = checkbox("语音时自动切换系统麦克风（松开还原真实麦克风）",
                                   target: #selector(autoSwitchToggled(_:)))
        monitorCheck = checkbox("说话时本机同时出声（双路输出）", target: #selector(monitorToggled(_:)))
        stack.addArrangedSubview(autoSwitchCheck)
        stack.addArrangedSubview(monitorCheck)

        addSeparator(to: stack, title: "输出设备（虚拟麦克风）")

        let deviceRow = NSStackView()
        deviceRow.orientation = .horizontal
        deviceRow.spacing = 8
        devicePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        devicePopup.target = self
        devicePopup.action = #selector(devicePicked(_:))
        let refresh = NSButton(title: "刷新音频设备", target: self, action: #selector(refreshDevices(_:)))
        refresh.bezelStyle = .rounded
        deviceRow.addArrangedSubview(label("送到：", size: 12))
        deviceRow.addArrangedSubview(devicePopup)
        deviceRow.addArrangedSubview(refresh)
        stack.addArrangedSubview(deviceRow)

        addSeparator(to: stack, title: "语音键")

        let keyRow = NSStackView()
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        voiceKeyPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        for mode in VoiceKeyMode.allCases {
            voiceKeyPopup.addItem(withTitle: mode.rawValue)
            voiceKeyPopup.lastItem?.representedObject = mode
        }
        voiceKeyPopup.selectItem(withTitle: model.voiceKeyMode.rawValue)
        voiceKeyPopup.target = self
        voiceKeyPopup.action = #selector(voiceKeyPicked(_:))
        tapToggle = checkbox("点按切换（开始/结束各按一下）", target: #selector(tapToggled(_:)))
        keyRow.addArrangedSubview(label("模拟按键：", size: 12))
        keyRow.addArrangedSubview(voiceKeyPopup)
        stack.addArrangedSubview(keyRow)
        stack.addArrangedSubview(tapToggle)

        axWarning = label("需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 斐讯麦",
                          size: 11)
        axWarning.textColor = .systemOrange
        stack.addArrangedSubview(axWarning)

        let hint = label(
            "Fn 长按（合成）兼容豆包/微信输入法的出厂长按快捷键；原生 F5 仅适合快捷键设为 F5 的工具。\n"
            + "遥控器语音由遥控器自主发起：按住即推流、松开即结束。",
            size: 11
        )
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        syncConnectionTab()
        return container
    }

    // MARK: - Tab 2 按键映射

    private func makeKeyMappingTab() -> NSView {
        let container = NSView()

        let diagram = RemoteDiagramView(frame: NSRect(x: 24, y: 30, width: 170, height: 400))
        container.addSubview(diagram)

        let right = NSStackView()
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        right.frame = NSRect(x: 230, y: 60, width: 380, height: 400)
        container.addSubview(right)

        arrowsMouseCheck = checkbox("方向键当鼠标用（按住移动，越按越快）",
                                    target: #selector(arrowsToggled(_:)))
        right.addArrangedSubview(arrowsMouseCheck)

        right.addArrangedSubview(label("自定义按键", size: 13, weight: .semibold))
        for button in MappedButton.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
            for action in KeyAction.allCases {
                popup.addItem(withTitle: action.label)
                popup.lastItem?.representedObject = action
            }
            let current = model.mappings[button.rawValue]
                ?? KeyAction.recommendedDefault(for: button, mouseMode: model.arrowsAsMouse)
            popup.selectItem(withTitle: current.label)
            popup.target = self
            popup.action = #selector(mappingPicked(_:))
            popup.identifier = NSUserInterfaceItemIdentifier(button.rawValue)
            mappingPopups[button] = popup
            row.addArrangedSubview(label(button.label + "：", size: 12, width: 90))
            row.addArrangedSubview(popup)
            right.addArrangedSubview(row)
        }

        right.addArrangedSubview(label("“系统默认”=不拦截，macOS 原生处理；改动即时生效。", size: 11))

        lastKeyLabel = label("最近按键：—", size: 12, weight: .semibold)
        right.addArrangedSubview(lastKeyLabel)

        syncMappingTab()
        return container
    }

    // MARK: - Tab 3 统计

    private func makeStatsTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 30, bottom: 20, right: 24)

        statLabels = (
            label("语音次数：0", size: 20, weight: .semibold),
            label("语音时长：0 秒", size: 20, weight: .semibold)
        )
        stack.addArrangedSubview(statLabels.count)
        stack.addArrangedSubview(statLabels.seconds)
        let note = label("统计只保存在本机，不上传。", size: 11)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)

        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        ])
        syncStats()
        return container
    }

    // MARK: - 同步

    private var lastConnSnapshot = ""
    private var lastMappingSnapshot = ""
    private var lastStatsSnapshot = ""
    private var lastDeviceListSnapshot = ""

    func syncConnectionTab() {
        let snapshot = "\(model.remoteName)|\(model.connectionState.rawValue)|\(model.voiceActive)|\(model.autoSwitchInput)|\(model.monitorEnabled)|\(model.voiceKeyTapToggle)|\(model.voiceKeyMode.rawValue)|\(model.accessibilityGranted)|\(model.selectedDeviceUID)|\(model.audioDevices.count)"
        guard snapshot != lastConnSnapshot else { return }
        lastConnSnapshot = snapshot

        statusLabel?.stringValue = "遥控器：\(model.remoteName) · \(model.connectionState.rawValue)"
        voiceStatusLabel?.stringValue = model.voiceActive ? "语音：说话中…" : "语音：待机"
        autoSwitchCheck?.state = model.autoSwitchInput ? .on : .off
        monitorCheck?.state = model.monitorEnabled ? .on : .off
        tapToggle?.state = model.voiceKeyTapToggle ? .on : .off
        axWarning?.isHidden = model.accessibilityGranted || model.voiceKeyMode == .none
        refreshDevicePopup()
    }

    func syncMappingTab() {
        let snapshot = "\(model.lastButton)|\(model.arrowsAsMouse)"
        guard snapshot != lastMappingSnapshot else { return }
        lastMappingSnapshot = snapshot
        lastKeyLabel?.stringValue = "最近按键：\(model.lastButton)"
        arrowsMouseCheck?.state = model.arrowsAsMouse ? .on : .off
    }

    func syncStats() {
        let snapshot = "\(model.todayVoiceCount)|\(model.todayVoiceSeconds)"
        guard snapshot != lastStatsSnapshot else { return }
        lastStatsSnapshot = snapshot
        statLabels?.count.stringValue = "语音次数：\(model.todayVoiceCount)"
        statLabels?.seconds.stringValue = String(format: "语音时长：%.0f 秒", model.todayVoiceSeconds)
    }

    private func refreshDevicePopup() {
        let listSnapshot = model.audioDevices.map { $0.uid }.joined(separator: ",")
        guard listSnapshot != lastDeviceListSnapshot || devicePopup?.numberOfItems == 0 else {
            // 列表没变，只校正选中项
            return
        }
        lastDeviceListSnapshot = listSnapshot
        devicePopup?.removeAllItems()
        devicePopup?.addItem(withTitle: "跟随系统默认")
        devicePopup?.lastItem?.representedObject = ""
        for device in model.audioDevices {
            devicePopup?.addItem(withTitle: device.name)
            devicePopup?.lastItem?.representedObject = device.uid
        }
        if model.selectedDeviceUID.isEmpty {
            devicePopup?.selectItem(at: 0)
        } else if let index = devicePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == model.selectedDeviceUID
        }) {
            devicePopup.selectItem(at: index)
        } else {
            let blackhole = model.audioDevices.first { $0.name.contains("BlackHole") }
            if let blackhole {
                devicePopup.selectItem(withTitle: blackhole.name)
            }
        }
    }

    // MARK: - 动作

    @objc private func devicePicked(_ sender: NSPopUpButton) {
        model.selectedDeviceUID = sender.selectedItem?.representedObject as? String ?? ""
    }

    @objc private func voiceKeyPicked(_ sender: NSPopUpButton) {
        if let mode = sender.selectedItem?.representedObject as? VoiceKeyMode {
            model.voiceKeyMode = mode
        }
        syncConnectionTab()
    }

    @objc private func tapToggled(_ sender: NSButton) {
        model.voiceKeyTapToggle = sender.state == .on
    }

    @objc private func autoSwitchToggled(_ sender: NSButton) {
        model.autoSwitchInput = sender.state == .on
    }

    @objc private func monitorToggled(_ sender: NSButton) {
        model.monitorEnabled = sender.state == .on
    }

    @objc private func arrowsToggled(_ sender: NSButton) {
        model.arrowsAsMouse = sender.state == .on
        syncMappingTab()
    }

    @objc private func mappingPicked(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue,
              let button = MappedButton(rawValue: raw),
              let action = sender.selectedItem?.representedObject as? KeyAction else { return }
        model.mappings[button.rawValue] = action
    }

    @objc private func refreshDevices(_ sender: NSButton) {
        model.refreshDevices()
        refreshDevicePopup()
    }

    // MARK: - 构造小件

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, width: CGFloat? = nil) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        if let width {
            l.frame = NSRect(x: 0, y: 0, width: width, height: size + 4)
        }
        return l
    }

    private func checkbox(_ title: String, target: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: target)
        b.font = .systemFont(ofSize: 12)
        return b
    }

    private func addSeparator(to stack: NSStackView, title: String) {
        let sep = NSBox()
        sep.boxType = .separator
        stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalToConstant: 560).isActive = true
        stack.addArrangedSubview(label(title, size: 13, weight: .semibold))
    }
}
