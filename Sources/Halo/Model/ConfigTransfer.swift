import AppKit
import UniformTypeIdentifiers

/// Import, export and reset of the configuration.
///
/// Import deliberately never trusts the incoming file to be self-consistent:
/// ids are re-issued on merge, and dangling sub-ring references are cleared, so
/// a shared ring set can't leave the user with nodes that beep and do nothing.
@MainActor
enum ConfigTransfer {

    // MARK: - Export

    enum ExportScope {
        case everything
        case ringsOnly
    }

    /// Payload written to disk. Rings-only exports omit keys and personal paths
    /// so a ring set can be shared without leaking the rest of the setup.
    private struct Bundle: Codable {
        var halo: String = "config"
        var version: Int = 2
        var exportedAt: Date = Date()
        var config: HaloConfig?
        var rings: [Ring]?
    }

    static func export(_ config: HaloConfig, scope: ExportScope) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = scope == .everything
            ? "Halo-settings.json" : "Halo-rings.json"
        panel.prompt = String(localized: "書き出す")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var bundle = Bundle()
        switch scope {
        case .everything:
            bundle.config = config
        case .ringsOnly:
            // Per-ring hot keys are personal to a machine; drop them.
            bundle.rings = config.rings.map { ring in
                var copy = ring
                copy.hotKey = nil
                return copy
            }
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(bundle).write(to: url, options: .atomic)
        } catch {
            report(String(localized: "書き出しに失敗しました"), error.localizedDescription)
        }
    }

    // MARK: - Import

    enum ImportMode {
        /// Replace the whole configuration with the file's.
        case replace
        /// Append the file's rings, keeping everything that is already there.
        case merge
    }

    /// Returns the new configuration, or nil when the user cancelled or the
    /// file could not be read.
    static func importConfig(into current: HaloConfig) -> HaloConfig? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "読み込む")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard let data = try? Data(contentsOf: url) else {
            report(String(localized: "読み込みに失敗しました"), url.lastPathComponent)
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Accept a Halo bundle, a rings-only bundle, or a bare config.json.
        var incomingConfig: HaloConfig?
        var incomingRings: [Ring]?
        if let bundle = try? decoder.decode(Bundle.self, from: data), bundle.halo == "config" {
            incomingConfig = bundle.config
            incomingRings = bundle.rings
        } else if let bare = try? decoder.decode(HaloConfig.self, from: data) {
            incomingConfig = bare
        }

        if incomingConfig == nil && incomingRings == nil {
            report(String(localized: "読み込めませんでした"), String(localized: "Halo の設定ファイルではないようです。"))
            return nil
        }

        let mode = askMode(canReplace: incomingConfig != nil)
        guard let mode else { return nil }

        switch mode {
        case .replace:
            guard var config = incomingConfig else { return nil }
            config = ConfigStore.migrate(config)
            return sanitised(config)
        case .merge:
            let rings = incomingRings ?? incomingConfig?.rings ?? []
            return sanitised(merge(rings, into: current))
        }
    }

    /// Appends rings under fresh ids, rewriting sub-ring references so the
    /// imported set keeps pointing at its own copies rather than the user's.
    nonisolated static func merge(_ incoming: [Ring], into current: HaloConfig) -> HaloConfig {
        var config = current
        var idMap: [String: String] = [:]

        for ring in incoming {
            let newID = "ring." + UUID().uuidString.prefix(8).lowercased()
            idMap[ring.id] = newID
        }

        for ring in incoming {
            var copy = ring
            copy.id = idMap[ring.id] ?? ring.id
            copy.hotKey = nil
            copy.items = ring.items.map { item in
                var newItem = item
                newItem.id = UUID()
                if newItem.action.kind == .subring,
                   let remapped = idMap[newItem.action.value] {
                    newItem.action.value = remapped
                }
                return newItem
            }
            if config.rings.contains(where: { $0.title == copy.title }) {
                copy.title += String(localized: "（読み込み）")
            }
            config.rings.append(copy)
        }
        return config
    }

    /// Clears references that do not resolve, so no node is a dead end.
    nonisolated static func sanitised(_ input: HaloConfig) -> HaloConfig {
        var config = input
        let ringIDs = Set(config.rings.map(\.id))

        for i in config.rings.indices {
            for j in config.rings[i].items.indices
            where config.rings[i].items[j].action.kind == .subring {
                let target = config.rings[i].items[j].action.value
                let resolvable = ringIDs.contains(target) || DynamicRing(rawValue: target) != nil
                if !resolvable {
                    config.rings[i].items[j].action = .empty
                }
            }
        }
        config.contextRules.removeAll { !ringIDs.contains($0.ringID) }
        if config.rootRing == nil, let first = config.rings.first {
            config.rootRingID = first.id
        }
        return config
    }

    private static func askMode(canReplace: Bool) -> ImportMode? {
        let alert = NSAlert()
        alert.messageText = String(localized: "設定を読み込みます")
        alert.informativeText = canReplace
            ? String(localized: "既存の設定を置き換えるか、リングだけを追加するかを選んでください。")
            : String(localized: "このファイルにはリングだけが含まれています。既存の設定に追加します。")
        if canReplace { alert.addButton(withTitle: String(localized: "すべて置き換える")) }
        alert.addButton(withTitle: String(localized: "リングを追加する"))
        alert.addButton(withTitle: String(localized: "キャンセル"))
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if canReplace {
            switch response {
            case .alertFirstButtonReturn:  return .replace
            case .alertSecondButtonReturn: return .merge
            default:                       return nil
            }
        } else {
            return response == .alertFirstButtonReturn ? .merge : nil
        }
    }

    // MARK: - Reset

    enum ResetScope: String, CaseIterable, Identifiable {
        case appearance
        case rings
        case triggers
        case context
        case ai
        case everything

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance: return String(localized: "外観だけを初期化")
            case .rings:      return String(localized: "リングを既定に戻す")
            case .triggers:   return String(localized: "ショートカットと召喚方法を初期化")
            case .context:    return String(localized: "コンテキストのルールを消去")
            case .ai:         return String(localized: "AI 設定を初期化")
            case .everything: return String(localized: "すべてを初期化")
            }
        }

        var detail: String {
            switch self {
            case .appearance: return String(localized: "サイズ・色・配置・挙動が既定値に戻ります。リングはそのままです。")
            case .rings:      return String(localized: "リングと項目が初回起動時の内容に戻ります。現在の構成は失われます。")
            case .triggers:   return String(localized: "召喚ショートカットと、修飾キー／マウスボタンの設定が戻ります。")
            case .context:    return String(localized: "アプリごとのリング切り替えルールをすべて削除します。リング自体は残ります。")
            case .ai:         return String(localized: "プロバイダ・モデル・プロンプトが既定に戻ります。Keychain のキーは消えません。")
            case .everything: return String(localized: "設定ファイルを初期状態に戻します。リング・外観・ショートカットすべてが失われます。")
            }
        }

        /// The confirmation question, written out per scope rather than glued
        /// together — "Reset appearance" + "?" does not translate.
        var confirmTitle: String {
            switch self {
            case .appearance: return String(localized: "外観を初期化しますか？")
            case .rings:      return String(localized: "リングを既定に戻しますか？")
            case .triggers:   return String(localized: "ショートカットと召喚方法を初期化しますか？")
            case .context:    return String(localized: "コンテキストのルールを消去しますか？")
            case .ai:         return String(localized: "AI 設定を初期化しますか？")
            case .everything: return String(localized: "すべてを初期化しますか？")
            }
        }

        var isDestructive: Bool {
            switch self {
            case .rings, .everything: return true
            default: return false
            }
        }
    }

    /// Applies a reset after confirming. Returns true when it went ahead.
    @discardableResult
    static func reset(_ scope: ResetScope, config: inout HaloConfig) -> Bool {
        guard confirm(scope) else { return false }
        apply(scope, to: &config)
        return true
    }

    /// The reset itself, with no UI attached so it can be reasoned about — and
    /// tested — on its own.
    nonisolated static func apply(_ scope: ResetScope, to config: inout HaloConfig) {
        let defaults = DefaultConfig.make()
        switch scope {
        case .appearance:
            config.appearance = .default
        case .rings:
            config.rings = defaults.rings
            config.rootRingID = defaults.rootRingID
            config.contextRules = defaults.contextRules
        case .triggers:
            config.hotKey = .default
            config.triggers = .default
            for i in config.rings.indices { config.rings[i].hotKey = nil }
        case .context:
            config.contextRules = []
        case .ai:
            config.ai = .default
        case .everything:
            config = defaults
        }
    }

    private static func confirm(_ scope: ResetScope) -> Bool {
        let alert = NSAlert()
        alert.messageText = scope.confirmTitle
        alert.informativeText = String(localized: "\(scope.detail)\n\nこの操作は取り消せません。")
        alert.alertStyle = scope.isDestructive ? .critical : .warning
        alert.addButton(withTitle: String(localized: "初期化"))
        alert.addButton(withTitle: String(localized: "キャンセル"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Helpers

    private static func report(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
