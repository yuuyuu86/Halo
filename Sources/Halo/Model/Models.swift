import Foundation
import AppKit

// MARK: - Action

/// What a ring item does when it is invoked.
enum ActionKind: String, Codable, CaseIterable {
    case launchApp
    case openURL
    case runShortcut
    case runScript
    case clipboard
    case system
    case subring
    case ai
    case none

    var displayName: String {
        switch self {
        case .launchApp:   return String(localized: "アプリを起動")
        case .openURL:     return String(localized: "URL を開く")
        case .runShortcut: return String(localized: "ショートカットを実行")
        case .runScript:   return String(localized: "シェルスクリプト")
        case .clipboard:   return String(localized: "クリップボード")
        case .system:      return String(localized: "システム操作")
        case .subring:     return String(localized: "サブリング")
        case .ai:          return "AI"
        case .none:        return String(localized: "何もしない")
        }
    }

    var symbol: String {
        switch self {
        case .launchApp:   return "app.badge"
        case .openURL:     return "link"
        case .runShortcut: return "square.stack.3d.up"
        case .runScript:   return "terminal"
        case .clipboard:   return "doc.on.clipboard"
        case .system:      return "gearshape"
        case .subring:     return "circle.circle"
        case .ai:          return "sparkles"
        case .none:        return "minus"
        }
    }
}

/// Clipboard sub-operations, stored in `HaloAction.value`.
enum ClipboardOp: String, Codable, CaseIterable {
    case copy            // put `argument` (or nothing) on the pasteboard
    case paste           // synthesise ⌘V into the previously frontmost app
    case pasteAsPlainText
    case clear
    case history         // open the dynamic clipboard-history ring

    var displayName: String {
        switch self {
        case .copy:             return String(localized: "テキストをコピー")
        case .paste:            return String(localized: "ペースト")
        case .pasteAsPlainText: return String(localized: "プレーンテキストでペースト")
        case .clear:            return String(localized: "クリップボードを消去")
        case .history:          return String(localized: "履歴リングを開く")
        }
    }
}

/// System sub-operations, stored in `HaloAction.value`.
enum SystemOp: String, Codable, CaseIterable {
    case lockScreen
    case sleepDisplay
    case screenshotArea
    case screenshotWindow
    case toggleDarkMode
    case missionControl
    case emptyTrash
    case haloPreferences
    case volumeUp
    case volumeDown
    case volumeMute
    case showDesktop
    case appSwitcher
    case quitFrontmostApp
    case hideOtherApps
    case newFinderWindow

    var displayName: String {
        switch self {
        case .lockScreen:      return String(localized: "画面をロック")
        case .sleepDisplay:    return String(localized: "ディスプレイをスリープ")
        case .screenshotArea:  return String(localized: "範囲スクリーンショット")
        case .screenshotWindow:return String(localized: "ウインドウのスクリーンショット")
        case .toggleDarkMode:  return String(localized: "ダークモード切替")
        case .missionControl:  return "Mission Control"
        case .emptyTrash:      return String(localized: "ゴミ箱を空にする")
        case .haloPreferences: return String(localized: "Halo の設定を開く")
        case .volumeUp:        return String(localized: "音量を上げる")
        case .volumeDown:      return String(localized: "音量を下げる")
        case .volumeMute:      return String(localized: "消音を切り替え")
        case .showDesktop:     return String(localized: "デスクトップを表示")
        case .appSwitcher:     return String(localized: "アプリ切替（起動中）")
        case .quitFrontmostApp:return String(localized: "最前面のアプリを終了")
        case .hideOtherApps:   return String(localized: "他のアプリを隠す")
        case .newFinderWindow: return String(localized: "新規 Finder ウインドウ")
        }
    }

    /// Operations worth a second look before they run.
    var isDestructive: Bool {
        switch self {
        case .emptyTrash, .quitFrontmostApp: return true
        default: return false
        }
    }
}

/// Where an AI action gets its input from.
enum AIInputSource: String, Codable, CaseIterable {
    case clipboard
    case selection
    /// Whatever the user typed into the ring before choosing this item.
    case typed
    case none

    var displayName: String {
        switch self {
        case .clipboard: return String(localized: "クリップボード")
        case .selection: return String(localized: "選択テキスト")
        case .typed:     return String(localized: "リングで入力した文字")
        case .none:      return String(localized: "入力なし")
        }
    }
}

extension RingItem {
    /// Free-input AI items stay on the ring no matter what is typed — they are
    /// the destination for the typing, so filtering them away is self-defeating.
    var ignoresRingFilter: Bool {
        action.kind == .ai && AIInputSource(rawValue: action.argument) == .typed
    }
}

/// Where the result of an action is delivered.
enum ResultSink: String, Codable, CaseIterable {
    case discard
    case clipboard
    case paste
    case notification

    var displayName: String {
        switch self {
        case .discard:      return String(localized: "破棄")
        case .clipboard:    return String(localized: "クリップボードへ")
        case .paste:        return String(localized: "その場にペースト")
        case .notification: return String(localized: "通知で表示")
        }
    }
}

struct HaloAction: Codable, Hashable {

    init() {}

    init(kind: ActionKind = .none, value: String = "", argument: String = "",
         sink: ResultSink = .discard, confirm: Bool = false) {
        self.kind = kind
        self.value = value
        self.argument = argument
        self.sink = sink
        self.confirm = confirm
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        kind     = d(.kind, ActionKind.none)
        value    = d(.value, "")
        argument = d(.argument, "")
        sink     = d(.sink, ResultSink.discard)
        confirm  = d(.confirm, false)
    }

    var kind: ActionKind = .none
    /// Primary payload. Meaning depends on `kind`:
    /// launchApp → app path or bundle id, openURL → url string, runShortcut → shortcut name,
    /// runScript → script source, clipboard → ClipboardOp, system → SystemOp,
    /// subring → ring id, ai → prompt template.
    var value: String = ""
    /// Secondary payload (script input, AI input source, copy text, …).
    var argument: String = ""
    /// What to do with produced output.
    var sink: ResultSink = .discard
    /// Ask before running. Set automatically for irreversible system
    /// operations, and available on any action the user wants to guard.
    var confirm: Bool = false

    static let empty = HaloAction()

    /// Confirmation copy, or nil when the action can just run.
    var confirmationPrompt: (title: String, detail: String)? {
        guard confirm else { return nil }
        switch kind {
        case .system:
            let op = SystemOp(rawValue: value)
            return (op?.displayName ?? String(localized: "システム操作"), String(localized: "この操作は取り消せません。"))
        case .runScript:
            return (String(localized: "スクリプトを実行しますか？"), String(value.prefix(240)))
        case .launchApp:
            return (String(localized: "アプリを起動しますか？"), value)
        case .openURL:
            return (String(localized: "URL を開きますか？"), value)
        default:
            return (String(localized: "実行しますか？"), "")
        }
    }

    static func subring(_ id: String) -> HaloAction {
        HaloAction(kind: .subring, value: id)
    }
    static func app(_ path: String) -> HaloAction {
        HaloAction(kind: .launchApp, value: path)
    }
    static func url(_ s: String) -> HaloAction {
        HaloAction(kind: .openURL, value: s)
    }
    static func script(_ s: String, sink: ResultSink = .discard) -> HaloAction {
        HaloAction(kind: .runScript, value: s, sink: sink)
    }
    static func clip(_ op: ClipboardOp, argument: String = "") -> HaloAction {
        HaloAction(kind: .clipboard, value: op.rawValue, argument: argument)
    }
    static func system(_ op: SystemOp) -> HaloAction {
        HaloAction(kind: .system, value: op.rawValue, confirm: op.isDestructive)
    }
}

// MARK: - Ring

struct RingItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String = String(localized: "新しい項目")
    /// SF Symbol name. Empty → Halo derives an icon (app icon, favicon-ish glyph, action glyph).
    var glyph: String = ""
    /// Optional per-item accent, "#RRGGBB".
    var tint: String? = nil
    var action: HaloAction = .empty
    var enabled: Bool = true

    /// Symbol actually rendered when no app icon is available.
    var effectiveGlyph: String {
        glyph.isEmpty ? action.kind.symbol : glyph
    }
}

struct Ring: Codable, Identifiable, Hashable {
    /// Stable string id, referenced by `.subring` actions and context rules.
    var id: String = UUID().uuidString
    var title: String = "Ring"
    var items: [RingItem] = []
    /// Optional dedicated hot key that opens this ring directly, skipping the
    /// root ring and any context rule. Optional so older files still decode.
    var hotKey: HotKeyConfig? = nil

    var activeItems: [RingItem] { items.filter(\.enabled) }
}

/// Rings that are generated at summon time rather than stored in the config.
enum DynamicRing: String, CaseIterable {
    case clipboardHistory = "halo.dynamic.clipboard"
    case runningApps      = "halo.dynamic.apps"

    var title: String {
        switch self {
        case .clipboardHistory: return String(localized: "クリップボード履歴")
        case .runningApps:      return String(localized: "起動中のアプリ")
        }
    }
}

// MARK: - Context

/// Maps the app that was frontmost at summon time to a ring.
struct ContextRule: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var bundleIdentifier: String = ""
    var displayName: String = ""
    var ringID: String = ""
    var enabled: Bool = true
}

// MARK: - Hot key

struct HotKeyConfig: Codable, Hashable {
    /// Virtual key code (kVK_*). -1 means "modifiers only" which we do not support via Carbon.
    var keyCode: UInt32 = 49          // Space
    /// Carbon modifier mask (optionKey, cmdKey, controlKey, shiftKey).
    var modifiers: UInt32 = 2048      // optionKey
    var enabled: Bool = true

    static let `default` = HotKeyConfig()
}

// MARK: - Alternative triggers

/// A physical modifier, distinguished left from right so "double-tap right ⌘"
/// can exist without stepping on the left one.
enum ModifierKey: String, Codable, CaseIterable {
    case leftCommand, rightCommand
    case leftOption, rightOption
    case leftControl, rightControl
    case leftShift, rightShift
    case fn

    var displayName: String {
        switch self {
        case .leftCommand:  return String(localized: "左 ⌘")
        case .rightCommand: return String(localized: "右 ⌘")
        case .leftOption:   return String(localized: "左 ⌥")
        case .rightOption:  return String(localized: "右 ⌥")
        case .leftControl:  return String(localized: "左 ⌃")
        case .rightControl: return String(localized: "右 ⌃")
        case .leftShift:    return String(localized: "左 ⇧")
        case .rightShift:   return String(localized: "右 ⇧")
        case .fn:           return "fn"
        }
    }

    /// Virtual key code reported by `flagsChanged` events.
    var keyCode: Int64 {
        switch self {
        case .leftCommand:  return 55
        case .rightCommand: return 54
        case .leftOption:   return 58
        case .rightOption:  return 61
        case .leftControl:  return 59
        case .rightControl: return 62
        case .leftShift:    return 56
        case .rightShift:   return 60
        case .fn:           return 63
        }
    }

    /// Flag that is set while the key is held.
    var flag: CGEventFlags {
        switch self {
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftOption, .rightOption:   return .maskAlternate
        case .leftControl, .rightControl: return .maskControl
        case .leftShift, .rightShift:     return .maskShift
        case .fn:                         return .maskSecondaryFn
        }
    }
}

/// Ways to summon Halo other than the global hot key.
///
/// Both routes need Accessibility permission because they read events the
/// system does not otherwise deliver to a background app. They stay off until
/// the user turns them on, so a fresh install never triggers a permission
/// prompt it has not earned.
struct TriggerConfig: Codable, Hashable {
    var doubleTapEnabled: Bool = false
    var doubleTapModifier: ModifierKey = .rightCommand
    /// Maximum gap between the two taps.
    var doubleTapWindow: Double = 0.35

    var mouseButtonEnabled: Bool = false
    /// 2 is the middle button; trackpads and mice expose extra buttons as 3, 4…
    var mouseButton: Int = 2

    var isAnyEnabled: Bool { doubleTapEnabled || mouseButtonEnabled }

    static let `default` = TriggerConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        doubleTapEnabled   = d(.doubleTapEnabled, false)
        doubleTapModifier  = d(.doubleTapModifier, ModifierKey.rightCommand)
        doubleTapWindow    = d(.doubleTapWindow, 0.35)
        mouseButtonEnabled = d(.mouseButtonEnabled, false)
        mouseButton        = d(.mouseButton, 2)
    }
}

// MARK: - Appearance

enum NodeShape: String, Codable, CaseIterable {
    case circle, roundedSquare, hexagon, diamond

    var displayName: String {
        switch self {
        case .circle:        return String(localized: "円")
        case .roundedSquare: return String(localized: "角丸")
        case .hexagon:       return String(localized: "六角形")
        case .diamond:       return String(localized: "ダイヤ")
        }
    }
}

enum CoreStyle: String, Codable, CaseIterable {
    case capsule, minimal, hidden

    var displayName: String {
        switch self {
        case .capsule: return String(localized: "カプセル")
        case .minimal: return String(localized: "文字のみ")
        case .hidden:  return String(localized: "非表示")
        }
    }
}

enum LabelPlacement: String, Codable, CaseIterable {
    case outside, inside, selectedOnly, hidden

    var displayName: String {
        switch self {
        case .outside:      return String(localized: "リングの外側")
        case .inside:       return String(localized: "リングの内側")
        case .selectedOnly: return String(localized: "選択中のみ")
        case .hidden:       return String(localized: "非表示")
        }
    }
}

enum BackdropStyle: String, Codable, CaseIterable {
    case none, dim, vignette, blur

    var displayName: String {
        switch self {
        case .none:     return String(localized: "なし")
        case .dim:      return String(localized: "全体を暗く")
        case .vignette: return String(localized: "リング周りだけ暗く")
        case .blur:     return String(localized: "背景をぼかす")
        }
    }
}

enum IconStyle: String, Codable, CaseIterable {
    case original, monochrome

    var displayName: String {
        switch self {
        case .original:   return String(localized: "アプリの色そのまま")
        case .monochrome: return String(localized: "モノクロ")
        }
    }
}

/// Everything about how the ring looks and feels.
///
/// Decoding is written by hand rather than synthesised: Halo adds options over
/// time, and a synthesised `init(from:)` throws on any key it has never seen.
/// Reading each field with `decodeIfPresent` means an older `config.json` keeps
/// working — and keeps the user's rings — when new options appear.
struct Appearance: Codable, Hashable {

    // 寸法
    var ringRadius: Double = 168
    var nodeSize: Double = 60
    var deadZone: Double = 46
    /// Distance past the ring that triggers "dive into sub-ring".
    var diveMargin: Double = 56
    var ringThickness: Double = 1.0
    var labelSize: Double = 11.0

    // 配置
    /// Where the first node sits, in degrees; 90 is straight up.
    var startAngleDegrees: Double = 90
    /// Total arc the nodes are spread over. 360 wraps the full circle.
    var sweepDegrees: Double = 360
    var clockwise: Bool = true

    // 形
    var nodeShape: NodeShape = .circle
    var coreStyle: CoreStyle = .capsule
    var labelPlacement: LabelPlacement = .outside

    // 光
    var accentHex: String = "#FFC46B"
    var secondaryHex: String = "#9B8CFF"
    var glowIntensity: Double = 1.0
    var showArc: Bool = true
    var showComet: Bool = true
    var showFilament: Bool = true
    var backdrop: BackdropStyle = .vignette
    var backdropStrength: Double = 0.34

    // アイコン
    var iconStyle: IconStyle = .original
    /// Draws 1…9 badges on the nodes so the number shortcuts are discoverable.
    var showKeyHints: Bool = false

    // 挙動
    /// Below this hold duration the ring stays open after the hot key is released.
    var stickyThreshold: Double = 0.28
    /// Dwell required in the centre to pop back to the parent ring.
    var ascendDwell: Double = 0.25
    var animationSpeed: Double = 1.0
    var autoDive: Bool = true
    var pullToAscend: Bool = true
    var scrollToRotate: Bool = true
    var numberKeyShortcuts: Bool = true
    var haptics: Bool = true

    static let `default` = Appearance()

    init() {}

    // MARK: Layout

    /// Angular layout for `count` nodes under the current settings.
    func layout(count: Int) -> RingLayout {
        RingLayout(startAngle: startAngleDegrees * .pi / 180,
                   sweep: min(max(sweepDegrees, 30), 360) * .pi / 180,
                   clockwise: clockwise,
                   count: count)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case ringRadius, nodeSize, deadZone, diveMargin, ringThickness, labelSize
        case startAngleDegrees, sweepDegrees, clockwise
        case nodeShape, coreStyle, labelPlacement
        case accentHex, secondaryHex, glowIntensity
        case showArc, showComet, showFilament, backdrop, backdropStrength
        case iconStyle, showKeyHints
        case stickyThreshold, ascendDwell, animationSpeed
        case autoDive, pullToAscend, scrollToRotate, numberKeyShortcuts, haptics
        /// Retired in favour of `labelPlacement`; still read so old files migrate.
        case showLabels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        ringRadius    = d(.ringRadius, 168)
        nodeSize      = d(.nodeSize, 60)
        deadZone      = d(.deadZone, 46)
        diveMargin    = d(.diveMargin, 56)
        ringThickness = d(.ringThickness, 1.0)
        labelSize     = d(.labelSize, 11.0)

        startAngleDegrees = d(.startAngleDegrees, 90)
        sweepDegrees      = d(.sweepDegrees, 360)
        clockwise         = d(.clockwise, true)

        nodeShape      = d(.nodeShape, NodeShape.circle)
        coreStyle      = d(.coreStyle, CoreStyle.capsule)
        labelPlacement = d(.labelPlacement, d(.showLabels, true) ? LabelPlacement.outside : .hidden)

        accentHex        = d(.accentHex, "#FFC46B")
        secondaryHex     = d(.secondaryHex, "#9B8CFF")
        glowIntensity    = d(.glowIntensity, 1.0)
        showArc          = d(.showArc, true)
        showComet        = d(.showComet, true)
        showFilament     = d(.showFilament, true)
        backdrop         = d(.backdrop, BackdropStyle.vignette)
        backdropStrength = d(.backdropStrength, 0.34)

        iconStyle    = d(.iconStyle, IconStyle.original)
        showKeyHints = d(.showKeyHints, false)

        stickyThreshold   = d(.stickyThreshold, 0.28)
        ascendDwell       = d(.ascendDwell, 0.25)
        animationSpeed    = d(.animationSpeed, 1.0)
        autoDive          = d(.autoDive, true)
        pullToAscend      = d(.pullToAscend, true)
        scrollToRotate    = d(.scrollToRotate, true)
        numberKeyShortcuts = d(.numberKeyShortcuts, true)
        haptics           = d(.haptics, true)
    }

    /// Written by hand because `showLabels` exists only as a legacy read key.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ringRadius, forKey: .ringRadius)
        try c.encode(nodeSize, forKey: .nodeSize)
        try c.encode(deadZone, forKey: .deadZone)
        try c.encode(diveMargin, forKey: .diveMargin)
        try c.encode(ringThickness, forKey: .ringThickness)
        try c.encode(labelSize, forKey: .labelSize)

        try c.encode(startAngleDegrees, forKey: .startAngleDegrees)
        try c.encode(sweepDegrees, forKey: .sweepDegrees)
        try c.encode(clockwise, forKey: .clockwise)

        try c.encode(nodeShape, forKey: .nodeShape)
        try c.encode(coreStyle, forKey: .coreStyle)
        try c.encode(labelPlacement, forKey: .labelPlacement)

        try c.encode(accentHex, forKey: .accentHex)
        try c.encode(secondaryHex, forKey: .secondaryHex)
        try c.encode(glowIntensity, forKey: .glowIntensity)
        try c.encode(showArc, forKey: .showArc)
        try c.encode(showComet, forKey: .showComet)
        try c.encode(showFilament, forKey: .showFilament)
        try c.encode(backdrop, forKey: .backdrop)
        try c.encode(backdropStrength, forKey: .backdropStrength)

        try c.encode(iconStyle, forKey: .iconStyle)
        try c.encode(showKeyHints, forKey: .showKeyHints)

        try c.encode(stickyThreshold, forKey: .stickyThreshold)
        try c.encode(ascendDwell, forKey: .ascendDwell)
        try c.encode(animationSpeed, forKey: .animationSpeed)
        try c.encode(autoDive, forKey: .autoDive)
        try c.encode(pullToAscend, forKey: .pullToAscend)
        try c.encode(scrollToRotate, forKey: .scrollToRotate)
        try c.encode(numberKeyShortcuts, forKey: .numberKeyShortcuts)
        try c.encode(haptics, forKey: .haptics)
    }
}

/// How nodes are distributed around the ring.
struct RingLayout {
    var startAngle: Double     // radians, y-up
    var sweep: Double          // radians
    var clockwise: Bool
    var count: Int

    /// A full circle wraps, so the last node must not land on the first;
    /// a partial arc should reach both ends.
    var step: Double {
        guard count > 1 else { return 0 }
        let isFullCircle = sweep >= 2 * .pi - 0.001
        return sweep / Double(isFullCircle ? count : count - 1)
    }

    func angle(at index: Int) -> Double {
        startAngle + (clockwise ? -1 : 1) * step * Double(index)
    }
}

// MARK: - AI

struct AIConfig: Codable, Hashable {

    var enabled: Bool = false
    /// Provider identifier. Only Apple's on-device model ships today; the
    /// field exists so adding one later does not need a migration.
    var provider: String = "apple"
    var systemPrompt: String =
        String(localized: "あなたは macOS のユーティリティです。前置きや説明を書かず、変換後のテキストだけを返してください。")
    var temperature: Double = 0.3
    var maxTokens: Int = 1024
    /// Show the answer for review before it touches the user's document.
    /// On by default: replacing a selection is a destructive edit.
    var reviewBeforeApplying: Bool = true

    static let `default` = AIConfig()

    /// Providers Halo can actually resolve. A configuration naming anything
    /// else — an old cloud provider, a typo in a hand-edited file — is repaired
    /// on load rather than failing at the moment the user invokes an AI item.
    static let knownProviders: Set<String> = ["apple"]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        enabled      = d(.enabled, false)
        provider     = d(.provider, "apple")
        systemPrompt = d(.systemPrompt, AIConfig.defaultSystemPrompt)
        temperature  = d(.temperature, 0.3)
        maxTokens    = d(.maxTokens, 1024)
        reviewBeforeApplying = d(.reviewBeforeApplying, true)
    }

    static let defaultSystemPrompt =
        String(localized: "あなたは macOS のユーティリティです。前置きや説明を書かず、変換後のテキストだけを返してください。")
}

// MARK: - Root config

struct HaloConfig: Codable {

    /// Schema version. `ConfigStore.migrate` brings older files up to this.
    static let currentVersion = 3

    var version: Int = HaloConfig.currentVersion
    var rings: [Ring] = []
    var rootRingID: String = ""
    var contextRules: [ContextRule] = []
    var hotKey: HotKeyConfig = .default
    var triggers: TriggerConfig = .default
    var appearance: Appearance = .default
    var ai: AIConfig = .default
    var launchAtLogin: Bool = false
    var clipboardHistoryEnabled: Bool = true
    var clipboardHistoryLimit: Int = 20

    init() {}

    /// Tolerant of missing keys for the same reason `Appearance` is: a config
    /// written by an older build must never cost the user their rings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        version                 = d(.version, 1)
        rings                   = d(.rings, [])
        rootRingID              = d(.rootRingID, "")
        contextRules            = d(.contextRules, [])
        hotKey                  = d(.hotKey, .default)
        triggers                = d(.triggers, .default)
        appearance              = d(.appearance, .default)
        ai                      = d(.ai, .default)
        launchAtLogin           = d(.launchAtLogin, false)
        clipboardHistoryEnabled = d(.clipboardHistoryEnabled, true)
        clipboardHistoryLimit   = d(.clipboardHistoryLimit, 20)
    }

    func ring(withID id: String) -> Ring? {
        rings.first { $0.id == id }
    }

    var rootRing: Ring? {
        ring(withID: rootRingID) ?? rings.first
    }
}
