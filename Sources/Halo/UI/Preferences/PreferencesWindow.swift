import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    static let shared = PreferencesWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = String(localized: "Halo 設定")
        window.titlebarAppearsTransparent = false
        window.center()
        window.setFrameAutosaveName("HaloPreferences")
        window.contentView = NSHostingView(rootView: PreferencesView())
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        // The prefs window is the one place Halo behaves like a normal app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        ConfigStore.shared.save()
        NSApp.setActivationPolicy(.accessory)
    }
}

struct PreferencesView: View {

    enum Tab: String, CaseIterable, Identifiable {
        case rings, context, hotkey, appearance, ai, backup, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .rings:      return String(localized: "リング")
            case .context:    return String(localized: "コンテキスト")
            case .hotkey:     return String(localized: "ショートカット")
            case .appearance: return String(localized: "外観")
            case .ai:         return "AI"
            case .backup:     return String(localized: "バックアップ / リセット")
            case .about:      return String(localized: "Halo について")
            }
        }

        var symbol: String {
            switch self {
            case .rings:      return "circle.circle"
            case .context:    return "app.connected.to.app.below.fill"
            case .hotkey:     return "keyboard"
            case .appearance: return "paintbrush"
            case .ai:         return "sparkles"
            case .backup:     return "arrow.up.arrow.down.square"
            case .about:      return "info.circle"
            }
        }
    }

    @State private var tab: Tab = .rings

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch tab {
                case .rings:      RingsPane()
                case .context:    ContextPane()
                case .hotkey:     HotKeyPane()
                case .appearance: AppearancePane()
                case .ai:         AIPane()
                case .backup:     BackupPane()
                case .about:      AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}
