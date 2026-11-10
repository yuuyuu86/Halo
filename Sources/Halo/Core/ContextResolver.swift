import AppKit

/// Decides which ring to summon, and builds the dynamic rings.
///
/// The Context Ring rule is simple on purpose: the app that was frontmost at
/// the moment of summoning wins; if no rule matches, the root ring is used.
@MainActor
enum ContextResolver {

    /// Ring to open for the given frontmost application.
    static func rootRing(for app: NSRunningApplication?, config: HaloConfig) -> Ring? {
        if let bundleID = app?.bundleIdentifier {
            let rule = config.contextRules.first {
                $0.enabled && $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
            }
            if let rule, let ring = config.ring(withID: rule.ringID) {
                return ring
            }
        }
        return config.rootRing
    }

    /// Resolves a `.subring` target, including the runtime-generated rings.
    static func resolve(ringID: String, config: HaloConfig) -> Ring? {
        if let dynamic = DynamicRing(rawValue: ringID) {
            return build(dynamic)
        }
        return config.ring(withID: ringID)
    }

    static func build(_ dynamic: DynamicRing) -> Ring {
        switch dynamic {
        case .clipboardHistory:
            let entries = ClipboardHistory.shared.entries.prefix(8)
            let items = entries.map { entry in
                RingItem(title: entry.preview,
                         glyph: "doc.plaintext",
                         action: .clip(.copy, argument: entry.text))
            }
            return Ring(id: dynamic.rawValue,
                        title: dynamic.title,
                        items: items.isEmpty
                            ? [RingItem(title: String(localized: "履歴なし"), glyph: "tray", action: .empty, enabled: true)]
                            : Array(items))

        case .runningApps:
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
                .prefix(10)
            let items = apps.map { app in
                RingItem(title: app.localizedName ?? "App",
                         glyph: "app",
                         action: .app(app.bundleIdentifier ?? app.bundleURL?.path ?? ""))
            }
            return Ring(id: dynamic.rawValue, title: dynamic.title, items: Array(items))
        }
    }
}
