import AppKit
import Carbon.HIToolbox

/// Registers the global hot keys through Carbon's `RegisterEventHotKey`.
///
/// Carbon is used deliberately: it delivers both *pressed* and *released*
/// events system-wide without requiring Accessibility permission, which is what
/// makes Halo's "hold to summon, release to invoke" gesture possible on a fresh
/// install.
///
/// More than one key can be live at a time — the main summon key plus one per
/// ring — so registrations are keyed by an id and dispatched back by target.
@MainActor
final class HotKeyManager {

    static let shared = HotKeyManager()

    /// What a registered key opens.
    enum Target: Equatable {
        case main
        case ring(String)
    }

    var onPressed: ((Target) -> Void)?
    var onReleased: ((Target) -> Void)?

    private var registrations: [UInt32: (ref: EventHotKeyRef, target: Target)] = [:]
    private var handlerRef: EventHandlerRef?
    private var installed = false
    private var nextID: UInt32 = 1

    private let signature: OSType = 0x48414C4F  // 'HALO'

    private init() {}

    // MARK: - Registration

    /// Replaces every registration in one go. Returns the targets whose key
    /// could not be claimed, so the UI can tell the user which combination is
    /// already taken by something else.
    @discardableResult
    func registerAll(main: HotKeyConfig, rings: [(ringID: String, config: HotKeyConfig)]) -> [Target] {
        unregisterAll()
        installHandlerIfNeeded()

        var failed: [Target] = []
        if !register(main, target: .main) { failed.append(.main) }
        for entry in rings where entry.config.enabled {
            if !register(entry.config, target: .ring(entry.ringID)) {
                failed.append(.ring(entry.ringID))
            }
        }
        return failed
    }

    @discardableResult
    private func register(_ config: HotKeyConfig, target: Target) -> Bool {
        guard config.enabled else { return true }

        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(config.keyCode,
                                         config.modifiers,
                                         EventHotKeyID(signature: signature, id: id),
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else {
            NSLog("Halo: RegisterEventHotKey failed (%d) — the combination may be taken.", status)
            return false
        }
        registrations[id] = (ref, target)
        return true
    }

    func unregisterAll() {
        for (_, entry) in registrations {
            UnregisterEventHotKey(entry.ref)
        }
        registrations.removeAll()
    }

    fileprivate func target(forHotKeyID id: UInt32) -> Target? {
        registrations[id]?.target
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else { return noErr }
            let kind = Int(GetEventKind(event))

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return noErr }
            let id = hotKeyID.id

            // The Carbon handler already runs on the main thread; hop through
            // assumeIsolated so the ring appears in the same run loop turn as
            // the key press.
            MainActor.assumeIsolated {
                let manager = HotKeyManager.shared
                guard let target = manager.target(forHotKeyID: id) else { return }
                switch kind {
                case kEventHotKeyPressed:  manager.onPressed?(target)
                case kEventHotKeyReleased: manager.onReleased?(target)
                default: break
                }
            }
            return noErr
        }

        InstallEventHandler(GetEventDispatcherTarget(),
                            callback,
                            eventTypes.count,
                            &eventTypes,
                            nil,
                            &handlerRef)
    }
}

// MARK: - Key naming

enum KeyCodeNames {

    /// Human readable form of a Carbon hot key, e.g. "⌥Space".
    static func describe(_ config: HotKeyConfig) -> String {
        guard config.enabled else { return String(localized: "無効") }
        return modifierString(config.modifiers) + keyName(config.keyCode)
    }

    static func modifierString(_ carbonModifiers: UInt32) -> String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }

    /// Convert AppKit modifier flags to the Carbon mask Carbon hot keys expect.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    private static let names: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Escape): "⎋", UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Grave): "`", UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12"
    ]

    static func keyName(_ code: UInt32) -> String {
        names[code] ?? "Key \(code)"
    }
}
