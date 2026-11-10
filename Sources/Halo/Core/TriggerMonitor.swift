import AppKit
import ApplicationServices

/// Summon routes that the Carbon hot key cannot cover: double-tapping a bare
/// modifier, and extra pointer buttons on a mouse or trackpad.
///
/// Both read the global event stream, which needs Accessibility permission, so
/// the tap is only created once the user actually enables one of them. The tap
/// is installed `listenOnly`: Halo never swallows an event, so a middle click
/// still reaches whatever is under the cursor and a stray ⌘ never goes missing.
@MainActor
final class TriggerMonitor {

    static let shared = TriggerMonitor()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var config = TriggerConfig.default

    /// Timestamp of the first tap of a potential double-tap.
    private var lastModifierTapAt: Date?
    /// True while the modifier that summoned the ring is still held.
    private var awaitingModifierRelease = false

    private init() {}

    // MARK: - Lifecycle

    /// Installs or tears down the tap to match `config`.
    /// Returns false when the tap was wanted but could not be created.
    @discardableResult
    func apply(_ config: TriggerConfig, promptForPermission: Bool = false) -> Bool {
        self.config = config
        stop()
        guard config.isAnyEnabled else { return true }

        guard AXIsProcessTrusted() else {
            if promptForPermission {
                PermissionCheck.ensureAccessibility(reason: "修飾キー／マウスボタンでの召喚")
            }
            return false
        }
        return start()
    }

    private func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.otherMouseDown.rawValue)
                 | (1 << CGEventType.otherMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            MainActor.assumeIsolated {
                TriggerMonitor.shared.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: nil) else {
            NSLog("Halo: could not create the event tap for alternative triggers.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        lastModifierTapAt = nil
        awaitingModifierRelease = false
    }

    // MARK: - Event handling

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables a slow tap; ours is cheap, so just switch it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged:
            handleFlagsChanged(event)

        case .otherMouseDown:
            guard config.mouseButtonEnabled, buttonNumber(of: event) == config.mouseButton else { return }
            RingController.shared.summon()

        case .otherMouseUp:
            guard config.mouseButtonEnabled, buttonNumber(of: event) == config.mouseButton else { return }
            RingController.shared.hotKeyReleased()

        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        guard config.doubleTapEnabled else { return }
        let modifier = config.doubleTapModifier
        guard event.getIntegerValueField(.keyboardEventKeycode) == modifier.keyCode else { return }

        let isDown = event.flags.contains(modifier.flag)

        guard isDown else {
            // Release closes a spring-loaded summon; a plain second release is
            // harmless because the controller ignores it when nothing is open.
            if awaitingModifierRelease {
                awaitingModifierRelease = false
                RingController.shared.hotKeyReleased()
            }
            return
        }

        let now = Date()
        if let last = lastModifierTapAt, now.timeIntervalSince(last) <= config.doubleTapWindow {
            lastModifierTapAt = nil
            awaitingModifierRelease = true
            RingController.shared.summon()
        } else {
            lastModifierTapAt = now
        }
    }

    private func buttonNumber(of event: CGEvent) -> Int {
        Int(event.getIntegerValueField(.mouseEventButtonNumber))
    }
}
