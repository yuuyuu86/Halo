import AppKit
import ApplicationServices

/// Carries out a ring item's action once the user commits to it.
///
/// Every branch is expected to fail softly: Halo dismisses the ring first, so a
/// failure here must never leave an invisible overlay on screen. Problems are
/// surfaced through `HaloNotifier` instead of throwing into the UI.
@MainActor
final class ActionExecutor {

    static let shared = ActionExecutor()
    private init() {}

    /// The app that was frontmost when the ring was summoned. Actions that
    /// synthesise keystrokes target it.
    var contextApp: NSRunningApplication?

    func perform(_ action: HaloAction, item: RingItem?) {
        if let prompt = action.confirmationPrompt, !confirmed(prompt, item: item) { return }
        run(action, item: item)
    }

    /// Modal confirmation for guarded actions. The ring is already gone by the
    /// time this runs, so the alert is the only thing on screen.
    private func confirmed(_ prompt: (title: String, detail: String), item: RingItem?) -> Bool {
        let alert = NSAlert()
        alert.messageText = item.map { "「\($0.title)」を実行しますか？" } ?? prompt.title
        alert.informativeText = prompt.detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "実行"))
        alert.addButton(withTitle: String(localized: "キャンセル"))
        NSApp.activate(ignoringOtherApps: true)
        let go = alert.runModal() == .alertFirstButtonReturn
        // Hand focus back to whatever the user was in before the alert stole it.
        if let contextApp, contextApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            contextApp.activate()
        }
        return go
    }

    private func run(_ action: HaloAction, item: RingItem?) {
        switch action.kind {
        case .none:
            break
        case .launchApp:
            launchApp(action.value)
        case .openURL:
            openURL(action.value)
        case .runShortcut:
            runShortcut(action)
        case .runScript:
            runScript(action)
        case .clipboard:
            runClipboard(action)
        case .system:
            runSystem(action)
        case .subring:
            // Handled by the ring controller; reaching here means a dangling id.
            HaloNotifier.failure(String(localized: "サブリングが見つかりません"), body: action.value)
        case .ai:
            runAI(action, item: item)
        }
    }

    // MARK: - App / URL

    private func launchApp(_ pathOrBundleID: String) {
        guard !pathOrBundleID.isEmpty else { return }
        let url: URL?
        if pathOrBundleID.hasPrefix("/") {
            url = URL(fileURLWithPath: pathOrBundleID)
        } else {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pathOrBundleID)
        }
        guard let url else {
            HaloNotifier.failure(String(localized: "アプリが見つかりません"), body: pathOrBundleID)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Task { @MainActor in
                    HaloNotifier.failure(String(localized: "起動に失敗しました"), body: error.localizedDescription)
                }
            }
        }
    }

    private func openURL(_ raw: String) {
        let expanded = expand(raw, urlEncodeSubstitutions: true)
        guard let url = URL(string: expanded), url.scheme != nil else {
            HaloNotifier.failure(String(localized: "URL が不正です"), body: expanded)
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Shortcuts

    private func runShortcut(_ action: HaloAction) {
        let name = action.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        var arguments = ["run", name]
        var input: String?
        if action.argument == "clipboard" {
            input = ClipboardHistory.shared.current
        } else if !action.argument.isEmpty {
            input = expand(action.argument)
        }
        if input != nil { arguments += ["--input-path", "-"] }

        Task.detached {
            let result = Shell.run("/usr/bin/shortcuts", arguments: arguments, stdin: input)
            await MainActor.run {
                ActionExecutor.shared.deliver(result, sink: action.sink,
                                              successTitle: "ショートカット: \(name)")
            }
        }
    }

    /// Names of the user's installed shortcuts, for the item editor.
    nonisolated static func installedShortcuts() -> [String] {
        let result = Shell.run("/usr/bin/shortcuts", arguments: ["list"], stdin: nil)
        guard result.status == 0 else { return [] }
        return result.output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Shell

    private func runScript(_ action: HaloAction) {
        let source = expand(action.value)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let stdin = action.argument == "clipboard" ? ClipboardHistory.shared.current : nil
        let sink = action.sink

        Task.detached {
            let result = Shell.run("/bin/zsh", arguments: ["-lc", source], stdin: stdin)
            await MainActor.run {
                ActionExecutor.shared.deliver(result, sink: sink, successTitle: String(localized: "スクリプト完了"))
            }
        }
    }

    // MARK: - Clipboard

    private func runClipboard(_ action: HaloAction) {
        guard let op = ClipboardOp(rawValue: action.value) else { return }
        switch op {
        case .copy:
            let text = action.argument.isEmpty ? "" : expand(action.argument)
            guard !text.isEmpty else { return }
            ClipboardHistory.shared.put(text)
        case .clear:
            NSPasteboard.general.clearContents()
            ClipboardHistory.shared.clear()
        case .paste:
            synthesizePaste(plainText: false)
        case .pasteAsPlainText:
            let text = ClipboardHistory.shared.current
            if !text.isEmpty { ClipboardHistory.shared.put(text) }
            synthesizePaste(plainText: true)
        case .history:
            HaloNotifier.failure(String(localized: "履歴リング"), body: String(localized: "サブリングとして開いてください"))
        }
    }

    /// Puts the user back in the app they were working in.
    func returnFocusToContextApp() {
        guard let contextApp, contextApp.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        contextApp.activate()
    }

    /// Re-activates the app that was frontmost at summon time and sends ⌘V.
    /// Requires Accessibility permission; asks once, then degrades quietly.
    func synthesizePaste(plainText: Bool, after delay: TimeInterval = 0.12) {
        guard PermissionCheck.ensureAccessibility(reason: String(localized: "ペースト操作")) else { return }
        contextApp?.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let vKey: CGKeyCode = 9  // kVK_ANSI_V
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
            var flags: CGEventFlags = .maskCommand
            if plainText { flags.insert(.maskShift); flags.insert(.maskAlternate) }
            down.flags = flags
            up.flags = flags
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    // MARK: - System

    private func runSystem(_ action: HaloAction) {
        guard let op = SystemOp(rawValue: action.value) else { return }
        switch op {
        case .lockScreen:
            Shell.detach("/usr/bin/pmset", arguments: ["displaysleepnow"])
        case .sleepDisplay:
            Shell.detach("/usr/bin/pmset", arguments: ["displaysleepnow"])
        case .screenshotArea:
            Shell.detach("/usr/sbin/screencapture", arguments: ["-i", "-c"])
        case .screenshotWindow:
            Shell.detach("/usr/sbin/screencapture", arguments: ["-i", "-w", "-c"])
        case .toggleDarkMode:
            let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
            Shell.detach("/usr/bin/osascript", arguments: ["-e", script])
        case .missionControl:
            Shell.detach("/usr/bin/open", arguments: ["-a", "Mission Control"])
        case .emptyTrash:
            let script = "tell application \"Finder\" to empty trash"
            Shell.detach("/usr/bin/osascript", arguments: ["-e", script])
        case .haloPreferences:
            PreferencesWindowController.shared.show()
        case .volumeUp:
            adjustVolume(by: +10)
        case .volumeDown:
            adjustVolume(by: -10)
        case .volumeMute:
            Shell.detach("/usr/bin/osascript",
                         arguments: ["-e", "set volume output muted (not (output muted of (get volume settings)))"])
        case .showDesktop:
            Shell.detach("/usr/bin/osascript",
                         arguments: ["-e", "tell application \"System Events\" to key code 103"])
        case .appSwitcher:
            // The ring controller intercepts this before the ring is dismissed;
            // arriving here means it was invoked outside a ring session.
            HaloNotifier.failure(String(localized: "アプリ切替"), body: String(localized: "リングから実行してください"))
        case .quitFrontmostApp:
            contextApp?.terminate()
        case .hideOtherApps:
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular
                    && $0.bundleIdentifier != contextApp?.bundleIdentifier
                    && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                .forEach { $0.hide() }
        case .newFinderWindow:
            Shell.detach("/usr/bin/osascript",
                         arguments: ["-e", "tell application \"Finder\" to make new Finder window"])
        }
    }

    /// Volume is nudged through AppleScript rather than synthesised media keys:
    /// it needs no extra permission and reports the real current level.
    private func adjustVolume(by delta: Int) {
        let script = """
        set current to output volume of (get volume settings)
        set volume output volume (current + (\(delta)))
        """
        Shell.detach("/usr/bin/osascript", arguments: ["-e", script])
    }

    // MARK: - AI

    /// Text the user typed into the ring before choosing this item. Captured at
    /// commit time because the ring — and its filter — is gone by the time the
    /// action runs.
    var typedText: String = ""

    private func runAI(_ action: HaloAction, item: RingItem?) {
        AIRun.shared.start(action: action, item: item)
    }

    // MARK: - Output routing

    private func deliver(_ result: Shell.Result, sink: ResultSink, successTitle: String) {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.status != 0 {
            let detail = result.error.isEmpty ? output : result.error
            HaloNotifier.failure(String(localized: "実行に失敗しました"),
                                 body: detail.isEmpty ? "終了コード \(result.status)" : detail)
            return
        }

        switch sink {
        case .discard:
            break
        case .clipboard:
            guard !output.isEmpty else { return }
            ClipboardHistory.shared.put(output)
            HaloNotifier.success(successTitle, body: String(localized: "クリップボードにコピーしました"))
        case .paste:
            guard !output.isEmpty else { return }
            ClipboardHistory.shared.put(output)
            synthesizePaste(plainText: false, after: 0.15)
        case .notification:
            HaloNotifier.success(successTitle, body: output.isEmpty ? String(localized: "完了") : String(output.prefix(300)))
        }
    }

    // MARK: - Placeholders

    /// Expands the placeholders Halo understands inside URLs, scripts and prompts.
    func expand(_ template: String, urlEncodeSubstitutions: Bool = false) -> String {
        guard template.contains("{") else { return template }

        func substitute(_ value: String) -> String {
            guard urlEncodeSubstitutions else { return value }
            return value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
        }

        var out = template
        let clipboard = ClipboardHistory.shared.current
        out = out.replacingOccurrences(of: "{clipboard}", with: substitute(clipboard))
        out = out.replacingOccurrences(of: "{selection}",
                                       with: substitute(SelectionReader.selectedText() ?? clipboard))
        out = out.replacingOccurrences(of: "{app}",
                                       with: substitute(contextApp?.localizedName ?? ""))
        out = out.replacingOccurrences(of: "{bundleID}",
                                       with: substitute(contextApp?.bundleIdentifier ?? ""))
        out = out.replacingOccurrences(of: "{date}",
                                       with: substitute(ISO8601DateFormatter().string(from: Date())))
        out = out.replacingOccurrences(of: "{home}", with: substitute(NSHomeDirectory()))
        return out
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}

// MARK: - Selection

/// Reads the text the user has selected in the app they were in.
///
/// Two routes, because neither is enough alone. The Accessibility API is clean
/// and side-effect free, but most apps — browsers and Electron ones especially
/// — do not publish a selection through it. The fallback synthesises ⌘C, which
/// works nearly everywhere at the cost of touching the pasteboard, so it takes
/// care to put the user's clipboard back exactly as it was.
@MainActor
enum SelectionReader {

    /// Best effort, preferring the side-effect-free route.
    static func selectedText() -> String? {
        if let viaAccessibility = accessibilitySelection() { return viaAccessibility }
        return copySelection()
    }

    /// Accessibility route: no side effects, but often returns nothing.
    static func accessibilitySelection() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &value) == .success,
              let text = value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Fallback: press ⌘C in the previously frontmost app, read what lands, and
    /// restore the pasteboard. Returns nil when nothing new arrived, which is
    /// what happens when there was no selection to copy.
    static func copySelection(timeout: TimeInterval = 0.45) -> String? {
        guard PermissionCheck.ensureAccessibility(reason: String(localized: "選択テキストの取得")) else { return nil }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let countBefore = pasteboard.changeCount

        ActionExecutor.shared.contextApp?.activate()
        postCommandC()

        // Polling beats a fixed sleep: most apps answer in a few milliseconds,
        // and the timeout only matters when there was nothing to copy.
        let deadline = Date().addingTimeInterval(timeout)
        var copied: String?
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            if pasteboard.changeCount != countBefore {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        restore(saved, to: pasteboard)

        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return copied
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 8  // kVK_ANSI_C
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Every representation on the pasteboard, so restoring keeps rich content
    /// (styled text, images) rather than flattening it to a string.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType: Data] {
        var saved: [NSPasteboard.PasteboardType: Data] = [:]
        for type in pasteboard.types ?? [] {
            if let data = pasteboard.data(forType: type) { saved[type] = data }
        }
        return saved
    }

    private static func restore(_ saved: [NSPasteboard.PasteboardType: Data], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        pasteboard.declareTypes(Array(saved.keys), owner: nil)
        for (type, data) in saved {
            pasteboard.setData(data, forType: type)
        }
        // Keep the restored contents out of the history as a new entry.
        ClipboardHistory.shared.ignoreNextChange()
    }
}

// MARK: - Feedback

/// Every user-visible message from an action goes through here.
///
/// Deliberately not User Notifications: those need an authorised, signed
/// bundle, and when authorisation is missing the failure is silent — exactly
/// the case where the user most needs to be told. The HUD always shows.
@MainActor
enum HaloNotifier {

    static func show(_ title: String, body: String) {
        HaloHUD.shared.show(title, body: body, kind: .info)
    }

    static func success(_ title: String, body: String) {
        HaloHUD.shared.show(title, body: body, kind: .success)
    }

    static func failure(_ title: String, body: String) {
        // Failures linger a little: they usually carry something to read.
        HaloHUD.shared.show(title, body: body, kind: .failure, duration: 4.0)
        NSLog("Halo: %@ — %@", title, body)
    }
}

// MARK: - Permissions

@MainActor
enum PermissionCheck {

    private static var didPrompt = false

    /// Returns true when Accessibility is granted. Prompts at most once per launch.
    @discardableResult
    static func ensureAccessibility(reason: String) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard !didPrompt else { return false }
        didPrompt = true

        let alert = NSAlert()
        alert.messageText = String(localized: "アクセシビリティ権限が必要です")
        alert.informativeText = """
        \(reason)には「システム設定 > プライバシーとセキュリティ > アクセシビリティ」で \
        Halo を許可してください。他の機能は権限なしでも動作します。
        """
        alert.addButton(withTitle: String(localized: "システム設定を開く"))
        alert.addButton(withTitle: String(localized: "後で"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}
