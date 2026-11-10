import Foundation
import AppKit

enum DefaultConfig {

    static let rootID   = "halo.root"
    static let devID    = "halo.dev"
    static let webID    = "halo.web"
    static let clipID   = "halo.clipboard"
    static let sysID    = "halo.system"
    static let safariID = "halo.context.safari"
    static let xcodeID  = "halo.context.xcode"
    static let aiID     = "halo.ai"

    /// First-run configuration. Apps that are not installed are dropped so the
    /// initial ring never contains dead entries.
    static func make() -> HaloConfig {
        var config = HaloConfig()
        config.rootRingID = rootID
        config.rings = [root(), dev(), web(), clipboard(), system(), ai(),
                        safariContext(), xcodeContext()]
        config.contextRules = [
            ContextRule(bundleIdentifier: "com.apple.Safari", displayName: "Safari", ringID: safariID),
            ContextRule(bundleIdentifier: "com.apple.dt.Xcode", displayName: "Xcode", ringID: xcodeID)
        ]
        return config
    }

    // MARK: rings

    private static func root() -> Ring {
        var items: [RingItem] = []
        items += appItem("Safari", glyph: "safari")
        items += appItem("Mail", glyph: "envelope")
        items.append(RingItem(title: "Web", glyph: "globe", action: .subring(webID)))
        items.append(RingItem(title: String(localized: "開発"), glyph: "chevron.left.forwardslash.chevron.right", action: .subring(devID)))
        items.append(RingItem(title: String(localized: "クリップ"), glyph: "doc.on.clipboard", action: .subring(clipID)))
        items.append(RingItem(title: String(localized: "システム"), glyph: "gearshape", action: .subring(sysID)))
        items.append(RingItem(title: "AI", glyph: "sparkles", action: .subring(aiID)))
        items.append(RingItem(title: String(localized: "スクショ"), glyph: "camera.viewfinder", action: .system(.screenshotArea)))
        items.append(RingItem(title: String(localized: "設定"), glyph: "slider.horizontal.3", action: .system(.haloPreferences)))
        return Ring(id: rootID, title: "Halo", items: items)
    }

    private static func dev() -> Ring {
        var items: [RingItem] = []
        items += appItem("Terminal", glyph: "terminal")
        items += appItem("Xcode", glyph: "hammer")
        items += appItem("Visual Studio Code", glyph: "chevron.left.forwardslash.chevron.right")
        items.append(RingItem(title: "GitHub", glyph: "point.3.filled.connected.trianglepath.dotted",
                              action: .url("https://github.com")))
        items.append(RingItem(title: String(localized: "ブランチ名"), glyph: "arrow.triangle.branch",
                              action: .script("cd \"$HOME\" && git rev-parse --abbrev-ref HEAD", sink: .clipboard)))
        items.append(RingItem(title: String(localized: "IP アドレス"), glyph: "network",
                              action: .script("ipconfig getifaddr en0", sink: .clipboard)))
        return Ring(id: devID, title: String(localized: "開発"), items: items)
    }

    private static func web() -> Ring {
        Ring(id: webID, title: "Web", items: [
            RingItem(title: String(localized: "検索"), glyph: "magnifyingglass",
                     action: HaloAction(kind: .openURL, value: "https://www.google.com/search?q={clipboard}")),
            RingItem(title: "YouTube", glyph: "play.rectangle", action: .url("https://www.youtube.com")),
            RingItem(title: "X", glyph: "at", action: .url("https://x.com")),
            RingItem(title: String(localized: "翻訳"), glyph: "character.book.closed",
                     action: HaloAction(kind: .openURL, value: "https://www.deepl.com/translator#auto/ja/{clipboard}")),
            RingItem(title: "Claude", glyph: "sparkles", action: .url("https://claude.ai"))
        ])
    }

    private static func clipboard() -> Ring {
        Ring(id: clipID, title: String(localized: "クリップボード"), items: [
            RingItem(title: String(localized: "履歴"), glyph: "clock.arrow.circlepath", action: .clip(.history)),
            RingItem(title: String(localized: "ペースト"), glyph: "arrow.down.doc", action: .clip(.paste)),
            RingItem(title: String(localized: "プレーン"), glyph: "textformat", action: .clip(.pasteAsPlainText)),
            RingItem(title: String(localized: "小文字化"), glyph: "textformat.size.smaller",
                     action: HaloAction(kind: .runScript, value: "tr '[:upper:]' '[:lower:]'",
                                        argument: "clipboard", sink: .clipboard)),
            RingItem(title: String(localized: "空白除去"), glyph: "arrow.left.and.right.text.vertical",
                     action: HaloAction(kind: .runScript, value: "tr -s ' ' | sed 's/^ *//;s/ *$//'",
                                        argument: "clipboard", sink: .clipboard)),
            RingItem(title: String(localized: "消去"), glyph: "trash", action: .clip(.clear))
        ])
    }

    private static func system() -> Ring {
        Ring(id: sysID, title: String(localized: "システム"), items: [
            RingItem(title: String(localized: "ロック"), glyph: "lock", action: .system(.lockScreen)),
            RingItem(title: String(localized: "画面スリープ"), glyph: "moon", action: .system(.sleepDisplay)),
            RingItem(title: String(localized: "ダークモード"), glyph: "circle.lefthalf.filled", action: .system(.toggleDarkMode)),
            RingItem(title: "Mission Control", glyph: "rectangle.3.group", action: .system(.missionControl)),
            RingItem(title: String(localized: "アプリ切替"), glyph: "square.stack", action: .subring(DynamicRing.runningApps.rawValue)),
            RingItem(title: String(localized: "ゴミ箱を空に"), glyph: "trash.slash", action: .system(.emptyTrash))
        ])
    }

    /// The AI ring. Every item runs on Apple's on-device model, so the prompts
    /// are written to be short and literal — small models follow narrow
    /// instructions far better than open-ended ones.
    static func ai() -> Ring {
        Ring(id: aiID, title: "AI", items: [
            aiItem(String(localized: "日本語に"), glyph: "character.book.closed",
                   prompt: String(localized: "次のテキストを自然な日本語に翻訳してください。\n\n{input}"),
                   source: .selection, sink: .paste),
            aiItem(String(localized: "英語に"), glyph: "textformat.abc",
                   prompt: "Translate the following text into natural English.\n\n{input}",
                   source: .selection, sink: .paste),
            aiItem(String(localized: "要約"), glyph: "text.line.first.and.arrowtriangle.forward",
                   prompt: String(localized: "次のテキストを日本語で 3 行以内に要約してください。\n\n{input}"),
                   source: .selection, sink: .clipboard),
            aiItem(String(localized: "整える"), glyph: "wand.and.sparkles",
                   prompt: String(localized: "次の文章の誤字脱字と不自然な言い回しを直してください。意味は変えないでください。\n\n{input}"),
                   source: .selection, sink: .paste),
            aiItem(String(localized: "丁寧に"), glyph: "hand.raised",
                   prompt: String(localized: "次の文章を、丁寧で礼儀正しい表現に書き直してください。\n\n{input}"),
                   source: .selection, sink: .paste),
            aiItem(String(localized: "コードを説明"), glyph: "chevron.left.forwardslash.chevron.right",
                   prompt: String(localized: "次のコードが何をしているかを日本語で簡潔に説明してください。\n\n{input}"),
                   source: .selection, sink: .notification),
            aiItem(String(localized: "自由入力"), glyph: "text.cursor",
                   prompt: "{input}",
                   source: .typed, sink: .clipboard)
        ])
    }

    private static func aiItem(_ title: String, glyph: String, prompt: String,
                               source: AIInputSource, sink: ResultSink) -> RingItem {
        RingItem(title: title, glyph: glyph,
                 action: HaloAction(kind: .ai, value: prompt,
                                    argument: source.rawValue, sink: sink))
    }

    private static func safariContext() -> Ring {
        Ring(id: safariID, title: "Safari", items: [
            RingItem(title: String(localized: "URL をコピー"), glyph: "link",
                     action: HaloAction(kind: .runScript,
                                        value: "osascript -e 'tell application \"Safari\" to return URL of front document'",
                                        sink: .clipboard)),
            RingItem(title: String(localized: "タイトルをコピー"), glyph: "text.quote",
                     action: HaloAction(kind: .runScript,
                                        value: "osascript -e 'tell application \"Safari\" to return name of front document'",
                                        sink: .clipboard)),
            RingItem(title: String(localized: "リーダー"), glyph: "eyeglasses",
                     action: HaloAction(kind: .runScript,
                                        value: "osascript -e 'tell application \"System Events\" to keystroke \"r\" using {command down, shift down}'")),
            RingItem(title: String(localized: "新規タブ"), glyph: "plus.rectangle.on.rectangle",
                     action: HaloAction(kind: .runScript,
                                        value: "osascript -e 'tell application \"Safari\" to make new tab at end of tabs of front window'")),
            RingItem(title: "Web", glyph: "globe", action: .subring(webID)),
            RingItem(title: String(localized: "クリップ"), glyph: "doc.on.clipboard", action: .subring(clipID))
        ])
    }

    private static func xcodeContext() -> Ring {
        Ring(id: xcodeID, title: "Xcode", items: [
            RingItem(title: String(localized: "ビルド"), glyph: "hammer",
                     action: HaloAction(kind: .runScript,
                                        value: "osascript -e 'tell application \"System Events\" to keystroke \"b\" using command down'")),
            RingItem(title: String(localized: "実行"), glyph: "play.fill",
                     action: HaloAction(kind: .runScript,
                                        value: "osascript -e 'tell application \"System Events\" to keystroke \"r\" using command down'")),
            RingItem(title: String(localized: "停止"), glyph: "stop.fill",
                     action: HaloAction(kind: .runScript,
                                        value: "osascript -e 'tell application \"System Events\" to keystroke \".\" using command down'")),
            RingItem(title: String(localized: "クリーン"), glyph: "sparkles",
                     action: HaloAction(kind: .runScript,
                                        value: "osascript -e 'tell application \"System Events\" to keystroke \"k\" using {command down, shift down}'")),
            RingItem(title: String(localized: "開発"), glyph: "chevron.left.forwardslash.chevron.right", action: .subring(devID))
        ])
    }

    // MARK: helpers

    /// Returns a single-element array when the app exists, otherwise empty.
    private static func appItem(_ name: String, glyph: String) -> [RingItem] {
        guard let path = AppIndex.path(forAppNamed: name) else { return [] }
        return [RingItem(title: name, glyph: glyph, action: .app(path))]
    }
}
