import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var aiCancelItem: NSMenuItem?
    private var configObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon

        _ = ConfigStore.shared
        ClipboardHistory.shared.start()

        setUpStatusItem()
        setUpHotKey()
        TriggerMonitor.shared.apply(ConfigStore.shared.config.triggers)

        LoginItem.sync(enabled: ConfigStore.shared.config.launchAtLogin)

        // Loading the on-device model takes a moment; do it now rather than on
        // the first summon, but only when AI is actually switched on.
        if #available(macOS 26.0, *), ConfigStore.shared.config.ai.enabled {
            AppleOnDeviceProvider.prewarm()
        }

        if !FileManager.default.fileExists(atPath: ConfigStore.fileURL.path) {
            ConfigStore.shared.save()
        }
        if isFirstRun && !isDebugSummonRun {
            WelcomeWindowController.shared.show()
            markFirstRunComplete()
        }

        scheduleDebugSummonIfRequested()
        DebugCommands.showPanelDemoIfRequested()
    }

    /// `Halo --summon-after 2` opens the ring unattended. Used for screenshots
    /// and for eyeballing the overlay without reaching for the hot key.
    private var isDebugSummonRun: Bool {
        CommandLine.arguments.contains("--summon-after")
    }

    private func scheduleDebugSummonIfRequested() {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--summon-after"),
              CommandLine.arguments.indices.contains(flagIndex + 1),
              let seconds = Double(CommandLine.arguments[flagIndex + 1]) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            RingController.shared.summon()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ConfigStore.shared.save()
        HotKeyManager.shared.unregisterAll()
        TriggerMonitor.shared.stop()
        ClipboardHistory.shared.stop()
    }

    // MARK: - Hot key

    func setUpHotKey() {
        let manager = HotKeyManager.shared
        manager.onPressed = { target in
            switch target {
            case .main:            RingController.shared.summon()
            case .ring(let id):    RingController.shared.summon(ringID: id)
            }
        }
        manager.onReleased = { _ in RingController.shared.hotKeyReleased() }
        refreshHotKeys()
    }

    /// Re-registers the main key plus every per-ring key. Safe to call whenever
    /// the configuration changes.
    @discardableResult
    func refreshHotKeys() -> [HotKeyManager.Target] {
        let config = ConfigStore.shared.config
        let ringKeys = config.rings.compactMap { ring -> (ringID: String, config: HotKeyConfig)? in
            guard let hotKey = ring.hotKey, hotKey.enabled else { return nil }
            return (ring.id, hotKey)
        }
        let failed = HotKeyManager.shared.registerAll(main: config.hotKey, rings: ringKeys)
        refreshHotKeyMenuTitle()
        return failed
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.statusImage()
            button.image?.isTemplate = true
            button.toolTip = "Halo"
        }

        let menu = NSMenu()
        let summon = NSMenuItem(title: String(localized: "Halo を呼び出す"),
                                action: #selector(summonNow), keyEquivalent: "")
        summon.target = self
        menu.addItem(summon)

        let hotKeyItem = NSMenuItem(
            title: String(localized: "ショートカット: ") + KeyCodeNames.describe(ConfigStore.shared.config.hotKey),
            action: nil, keyEquivalent: "")
        hotKeyItem.isEnabled = false
        menu.addItem(hotKeyItem)

        menu.addItem(.separator())

        let prefs = NSMenuItem(title: String(localized: "設定…"), action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let welcome = NSMenuItem(title: String(localized: "使い方を見る"), action: #selector(openWelcome), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)

        // Only meaningful mid-run; hidden the rest of the time so the menu does
        // not carry a permanently dead entry.
        let cancelAI = NSMenuItem(title: String(localized: "AI の実行を中止"), action: #selector(cancelAI), keyEquivalent: "")
        cancelAI.target = self
        cancelAI.isHidden = true
        menu.addItem(cancelAI)
        aiCancelItem = cancelAI
        menu.delegate = self

        menu.addItem(.separator())

        let quit = NSMenuItem(title: String(localized: "Halo を終了"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    /// Menu bar glyph: a ring with a single lit node — Halo in miniature.
    private static func statusImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 3, dy: 3)
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: inset)
            ring.lineWidth = 1.3
            ring.stroke()

            let dotSize: CGFloat = 4.2
            let dot = NSBezierPath(ovalIn: NSRect(x: rect.midX - dotSize / 2,
                                                  y: inset.maxY - dotSize / 2,
                                                  width: dotSize, height: dotSize))
            NSColor.black.setFill()
            dot.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func summonNow() { RingController.shared.summon() }
    @objc private func openPreferences() { PreferencesWindowController.shared.show() }
    @objc private func openWelcome() { WelcomeWindowController.shared.show() }
    @objc private func cancelAI() { AIRun.shared.cancel() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Called by the preferences UI when the hot key changes.
    func refreshHotKeyMenuTitle() {
        statusItem?.menu?.item(at: 1)?.title =
            String(localized: "ショートカット: ") + KeyCodeNames.describe(ConfigStore.shared.config.hotKey)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        aiCancelItem?.isHidden = !AIRun.shared.isRunning
    }

    // MARK: - First run

    private var isFirstRun: Bool {
        !UserDefaults.standard.bool(forKey: "halo.didCompleteFirstRun")
    }

    private func markFirstRunComplete() {
        UserDefaults.standard.set(true, forKey: "halo.didCompleteFirstRun")
    }
}

// MARK: - Login item

enum LoginItem {
    static func sync(enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Halo: login item update failed — %@", error.localizedDescription)
        }
    }
}
