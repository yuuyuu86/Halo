import AppKit
import SwiftUI

/// Borderless, transparent panel that covers the screen holding the cursor.
///
/// Covering the whole screen (rather than a small window around the cursor)
/// keeps the ring free to bloom, glow and spill labels outward without ever
/// being clipped by its own window.
final class HaloPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
}

@MainActor
final class HaloPanelController {

    static let shared = HaloPanelController()

    private var panel: HaloPanel?
    private var hostingView: NSHostingView<HaloRingView>?
    private var monitors: [Any] = []
    private var hideWorkItem: DispatchWorkItem?
    private var previousApp: NSRunningApplication?

    private init() {}

    // MARK: - Presentation

    func show(on screen: NSScreen) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        previousApp = NSWorkspace.shared.frontmostApplication

        let panel = self.panel ?? HaloPanel(screen: screen)
        panel.setFrame(screen.frame, display: false)

        if hostingView == nil {
            let view = NSHostingView(rootView: HaloRingView())
            view.frame = CGRect(origin: .zero, size: screen.frame.size)
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            hostingView = view
        } else {
            hostingView?.frame = CGRect(origin: .zero, size: screen.frame.size)
        }

        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        installMonitors()
    }

    func hide(after delay: TimeInterval, completion: @escaping () -> Void) {
        removeMonitors()
        hideWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            // Hand focus back so the ring never steals it from the app the user
            // was actually working in.
            if let previousApp = self.previousApp,
               previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApp.activate()
            }
            completion()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Event monitors

    private func installMonitors() {
        guard monitors.isEmpty else { return }

        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let box = MainThreadBox(event)
            return MainActor.assumeIsolated {
                MainThreadBox(RingController.shared.handleKeyDown(box.value) ? nil : box.value)
            }.value
        }

        let clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            let box = MainThreadBox(event)
            return MainActor.assumeIsolated { () -> MainThreadBox<NSEvent?> in
                let controller = RingController.shared
                guard controller.isVisible else { return MainThreadBox(box.value) }
                controller.handleClick(at: NSEvent.mouseLocation,
                                       rightButton: box.value.type == .rightMouseDown)
                return MainThreadBox(nil)
            }.value
        }

        // A scroll gesture rotates the selection — handy on a trackpad while the
        // ring is sticky.
        let scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let box = MainThreadBox(event)
            return MainActor.assumeIsolated { () -> MainThreadBox<NSEvent?> in
                guard RingController.shared.isVisible else { return MainThreadBox(box.value) }
                RingController.shared.handleScroll(deltaY: box.value.scrollingDeltaY)
                return MainThreadBox(nil)
            }.value
        }

        monitors = [keyMonitor, clickMonitor, scrollMonitor].compactMap { $0 }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }
}
