import AppKit
import Combine
import SwiftUI

/// Drives one summoning session: which rings are stacked, where the cursor is
/// relative to the summon point, what is selected, and how the session ends.
///
/// Interaction model
/// -----------------
/// * Hold the hot key, flick toward a node, release → invoke.
/// * Tap the hot key (shorter than `stickyThreshold`) → the ring stays open and
///   behaves like a normal click-through menu.
/// * Push *outward* past the ring while a sub-ring node is selected → dive in.
/// * Pull back *inward* to the core and dwell → surface to the parent ring.
@MainActor
final class RingController: ObservableObject {

    static let shared = RingController()

    // MARK: Published state

    /// Ring stack; the last element is the active ring.
    @Published private(set) var stack: [Ring] = []
    @Published private(set) var selection: Int?
    /// Cursor offset from the summon centre, in points, y-up (screen convention).
    @Published private(set) var cursorVector: CGPoint = .zero
    @Published private(set) var isVisible = false
    /// True once the hot key has been released in tap-mode, so the ring persists.
    @Published private(set) var sticky = false
    /// Drives the entrance/exit animation in the view.
    @Published private(set) var presentationProgress: Double = 0
    /// Live text filter. Typing while the ring is open narrows it down, which is
    /// what makes long rings — clipboard history, running apps — usable.
    @Published private(set) var filter: String = ""

    /// Items actually on the ring right now: the active ones, narrowed by the
    /// filter. Everything — drawing, selection, execution — goes through this,
    /// so indices can never disagree between the view and the controller.
    var visibleItems: [RingItem] {
        let items = activeRing?.activeItems ?? []
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { $0.ignoresRingFilter || $0.title.lowercased().contains(query) }
    }

    // MARK: Session state

    /// True while drawing into `PreviewRenderer`, where nothing animates and
    /// appear-driven effects would freeze at their first frame.
    private(set) var isOffscreenRender = false

    private(set) var center: CGPoint = .zero          // screen coords, y-up
    private(set) var screenFrame: CGRect = .zero
    private var summonedAt: Date = .distantPast
    private var trackingTimer: Timer?
    private var centerDwellStart: Date?
    private var diveArmed = true
    /// Descending and ascending both warp the cursor back to the centre, which
    /// would instantly re-satisfy the "pull inward to surface" condition. The
    /// gesture only re-arms once the cursor has left the dead zone again.
    private var ascendArmed = false
    /// Whether the summon key is still held. Descending after the key is gone
    /// has to switch the ring into click mode, or it would sit there inert.
    private var hotKeyIsDown = false

    private var appearance: Appearance { ConfigStore.shared.config.appearance }
    private var config: HaloConfig { ConfigStore.shared.config }

    var activeRing: Ring? { stack.last }
    var depth: Int { stack.count }

    private init() {}

    // MARK: - Session lifecycle

    /// Called on hot key press (or from the menu bar item).
    ///
    /// `ringID` bypasses context resolution: a ring with its own hot key opens
    /// that ring wherever you are.
    func summon(ringID: String? = nil) {
        if isVisible {
            // Second press while open acts as a cancel — never leave a ghost ring.
            dismiss()
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        ActionExecutor.shared.contextApp = frontmost

        let resolved = ringID.flatMap { ContextResolver.resolve(ringID: $0, config: config) }
            ?? ContextResolver.rootRing(for: frontmost, config: config)
        guard let ring = resolved, !ring.activeItems.isEmpty else {
            NSSound.beep()
            return
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }

        screenFrame = screen.frame
        center = clampedCenter(for: mouse, in: screen.frame)

        // Keep the cursor and the ring's centre coincident even near a screen
        // edge, so every node stays the same flick away.
        if center != mouse {
            warpCursor(to: center)
        }

        stack = [ring]
        selection = nil
        cursorVector = .zero
        sticky = false
        filter = ""
        diveArmed = true
        ascendArmed = false
        centerDwellStart = nil
        summonedAt = Date()
        hotKeyIsDown = true
        isVisible = true

        HaloPanelController.shared.show(on: screen)
        startTracking()
        Announcer.announceRing(ring, itemCount: ring.activeItems.count, depth: 1)

        withAnimation(.spring(response: 0.34 / max(appearance.animationSpeed, 0.2),
                              dampingFraction: 0.78)) {
            presentationProgress = 1
        }
    }

    /// Called on hot key release.
    func hotKeyReleased() {
        hotKeyIsDown = false
        guard isVisible else { return }
        let held = Date().timeIntervalSince(summonedAt)

        if held < appearance.stickyThreshold && selection == nil {
            sticky = true          // tap-to-open: keep the ring up for clicking
            return
        }
        commitSelection()
    }

    /// Invoke the current selection, or dismiss when nothing is selected.
    func commitSelection() {
        guard isVisible else { return }
        guard let index = selection, let item = itemAt(index) else {
            dismiss()
            return
        }

        if item.action.kind == .subring {
            descend(into: item.action.value)
            return
        }
        if item.action.kind == .clipboard,
           ClipboardOp(rawValue: item.action.value) == .history {
            descend(into: DynamicRing.clipboardHistory.rawValue)
            return
        }
        if item.action.kind == .system,
           SystemOp(rawValue: item.action.value) == .appSwitcher {
            descend(into: DynamicRing.runningApps.rawValue)
            return
        }

        let action = item.action
        ActionExecutor.shared.typedText = filter.trimmingCharacters(in: .whitespaces)
        dismiss()
        // Run after the overlay is gone *and* focus has returned to the app the
        // user was in, so synthesised keystrokes and ⌘V land in the right place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            ActionExecutor.shared.perform(action, item: item)
        }
    }

    func dismiss() {
        guard isVisible else { return }
        hotKeyIsDown = false
        stopTracking()
        isVisible = false
        sticky = false

        withAnimation(.easeIn(duration: 0.13 / max(appearance.animationSpeed, 0.2))) {
            presentationProgress = 0
        }
        HaloPanelController.shared.hide(after: 0.15) { [weak self] in
            guard let self else { return }
            if !self.isVisible {
                self.stack = []
                self.selection = nil
                self.filter = ""
            }
        }
    }

    // MARK: - Navigation

    /// How deep the ring stack may go.
    ///
    /// Nothing stops a user from pointing a ring's sub-ring item back at itself,
    /// and the dive gesture re-arms as soon as the cursor is warped home — so
    /// without a ceiling the stack, and the echo rings drawn from it, grow for
    /// as long as someone keeps flicking outward.
    static let maximumDepth = 6

    func descend(into ringID: String) {
        guard stack.count < Self.maximumDepth else {
            NSSound.beep()
            HaloNotifier.show("これ以上潜れません",
                              body: "リングの階層は \(Self.maximumDepth) 段までです")
            return
        }
        guard let ring = ContextResolver.resolve(ringID: ringID, config: config),
              !ring.activeItems.isEmpty else {
            NSSound.beep()
            return
        }
        // Re-entering the ring you are already on would just redraw it.
        guard ring.id != activeRing?.id else {
            NSSound.beep()
            return
        }
        stack.append(ring)
        selection = nil
        filter = ""
        cursorVector = .zero
        diveArmed = false           // require re-entry to the core before diving again
        ascendArmed = false         // …and don't bounce straight back out
        centerDwellStart = nil
        if !hotKeyIsDown { sticky = true }
        warpCursor(to: center)
        Announcer.announceRing(ring, itemCount: ring.activeItems.count, depth: stack.count)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.8)) {}
    }

    func ascend() {
        guard stack.count > 1 else { return }
        stack.removeLast()
        selection = nil
        filter = ""
        cursorVector = .zero
        diveArmed = false
        ascendArmed = false
        centerDwellStart = nil
        warpCursor(to: center)
        Announcer.announceRing(activeRing, itemCount: visibleItems.count, depth: stack.count)
    }

    // MARK: - Cursor tracking

    private func startTracking() {
        stopTracking()
        // 120 Hz polling: reading the global mouse location works whether or not
        // the panel is key, and avoids depending on event routing.
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in
            MainActor.assumeIsolated { RingController.shared.tick() }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func tick() {
        guard isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let vector = CGPoint(x: mouse.x - center.x, y: mouse.y - center.y)
        cursorVector = vector

        let distance = hypot(vector.x, vector.y)
        let items = visibleItems
        guard !items.isEmpty else {
            if selection != nil { selection = nil }
            return
        }

        // --- selection ---
        if distance < appearance.deadZone {
            if selection != nil { selection = nil }
        } else {
            let index = RingGeometry.nearestIndex(to: vector,
                                                  layout: appearance.layout(count: items.count))
            if selection != index {
                selection = index
                if appearance.haptics {
                    NSHapticFeedbackManager.defaultPerformer
                        .perform(.alignment, performanceTime: .now)
                }
                Announcer.announceSelection(itemAt(index), index: index, of: items.count)
            }
        }

        // --- pull inward to surface ---
        if distance > appearance.deadZone { ascendArmed = true }
        if appearance.pullToAscend, ascendArmed,
           distance < appearance.deadZone * 0.62, stack.count > 1 {
            if let start = centerDwellStart {
                if Date().timeIntervalSince(start) >= appearance.ascendDwell {
                    centerDwellStart = nil
                    ascend()
                    return
                }
            } else {
                centerDwellStart = Date()
            }
        } else {
            centerDwellStart = nil
        }

        // --- push outward to dive ---
        if distance < appearance.ringRadius * 0.72 { diveArmed = true }
        let diveDistance = appearance.ringRadius + appearance.diveMargin
        if appearance.autoDive, diveArmed, distance > diveDistance,
           let index = selection, let item = itemAt(index) {
            if item.action.kind == .subring {
                diveArmed = false
                descend(into: item.action.value)
            } else if item.action.kind == .clipboard,
                      ClipboardOp(rawValue: item.action.value) == .history {
                diveArmed = false
                descend(into: DynamicRing.clipboardHistory.rawValue)
            } else if item.action.kind == .system,
                      SystemOp(rawValue: item.action.value) == .appSwitcher {
                diveArmed = false
                descend(into: DynamicRing.runningApps.rawValue)
            }
        }
    }

    // MARK: - Keyboard / mouse from the panel

    /// Returns true when the event was consumed.
    ///
    /// Typing narrows the ring, so the keys that would otherwise be shortcuts
    /// (digits, Delete, Esc) change meaning while a filter is active. The rule
    /// is consistent: the filter is peeled back first, then normal navigation.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        let filtering = !filter.isEmpty

        switch Int(event.keyCode) {
        case 53:                                  // Escape
            filtering ? setFilter("") : dismiss()
            return true
        case 36, 76:                              // Return / Enter
            commitSelection(); return true
        case 49:                                  // Space
            // Space is a legitimate filter character once one is being typed.
            if filtering { appendToFilter(" ") } else { commitSelection() }
            return true
        case 48:                                  // Tab
            ascend(); return true
        case 51:                                  // Delete
            if filtering {
                setFilter(String(filter.dropLast()))
            } else {
                ascend()
            }
            return true
        case 123:                                 // ←
            step(-1); return true
        case 124:                                 // →
            step(1); return true
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers,
              !event.modifierFlags.contains(.command) else { return false }

        // Number keys jump straight to a node — 1 is the first node — but only
        // while nothing is being typed, so digits can still be searched for.
        if appearance.numberKeyShortcuts, !filtering,
           let digit = Int(characters), digit >= 1, digit <= visibleItems.count {
            selection = digit - 1
            commitSelection()
            return true
        }

        if isFilterable(characters) {
            appendToFilter(characters)
            return true
        }
        return false
    }

    /// Printable, non-control input that makes sense in a search field.
    private func isFilterable(_ characters: String) -> Bool {
        guard !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
        }
    }

    private func appendToFilter(_ characters: String) {
        setFilter(filter + characters)
    }

    /// Keeps the selection pointing at something real as the list shrinks.
    private func setFilter(_ newValue: String) {
        guard newValue != filter else { return }
        let previouslySelected = selection.flatMap { itemAt($0) }
        filter = newValue

        let items = visibleItems
        if items.isEmpty {
            selection = nil
        } else if let previouslySelected,
                  let index = items.firstIndex(where: { $0.id == previouslySelected.id }) {
            selection = index          // follow the item, not the index
        } else if let current = selection {
            selection = min(current, items.count - 1)
        }
        Announcer.announce(items.isEmpty ? "一致なし" : "\(items.count) 件", interrupts: false)
    }

    func handleClick(at pointInScreen: CGPoint, rightButton: Bool) {
        guard isVisible else { return }
        if rightButton {
            stack.count > 1 ? ascend() : dismiss()
            return
        }
        let vector = CGPoint(x: pointInScreen.x - center.x, y: pointInScreen.y - center.y)
        let distance = hypot(vector.x, vector.y)
        if distance < appearance.deadZone {
            stack.count > 1 ? ascend() : dismiss()
            return
        }
        let items = visibleItems
        if !items.isEmpty {
            selection = RingGeometry.nearestIndex(
                to: vector, layout: appearance.layout(count: items.count))
        }
        commitSelection()
    }

    private var scrollAccumulator: Double = 0

    /// Trackpad / wheel scrolling rotates the selection one node at a time.
    func handleScroll(deltaY: CGFloat) {
        guard appearance.scrollToRotate, isVisible, !visibleItems.isEmpty else { return }
        scrollAccumulator += Double(deltaY)
        let threshold = 8.0
        while abs(scrollAccumulator) >= threshold {
            step(scrollAccumulator > 0 ? -1 : 1)
            scrollAccumulator -= (scrollAccumulator > 0 ? threshold : -threshold)
        }
    }

    private func step(_ delta: Int) {
        let count = visibleItems.count
        guard count > 0 else { return }
        let current = selection ?? 0
        let next = ((current + delta) % count + count) % count
        selection = next
        Announcer.announceSelection(itemAt(next), index: next, of: count)
    }

    // MARK: - Helpers

    func itemAt(_ index: Int) -> RingItem? {
        let items = visibleItems
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// Keeps the whole ring (plus label ring and dive margin) on screen.
    private func clampedCenter(for point: CGPoint, in frame: CGRect) -> CGPoint {
        let margin = appearance.ringRadius + appearance.nodeSize / 2 + 46
        let minX = frame.minX + margin, maxX = frame.maxX - margin
        let minY = frame.minY + margin, maxY = frame.maxY - margin
        // Tiny screens: fall back to the centre rather than inverting the range.
        let x = minX <= maxX ? min(max(point.x, minX), maxX) : frame.midX
        let y = minY <= maxY ? min(max(point.y, minY), maxY) : frame.midY
        return CGPoint(x: x, y: y)
    }

    /// Populates just enough state for `PreviewRenderer` to draw a ring without
    /// a panel, a hot key, or a real cursor.
    func prepareForOffscreenRender(size: CGSize, depth: Int, selection: Int?,
                                   filter: String = "", ringID: String? = nil) {
        screenFrame = CGRect(origin: .zero, size: size)
        center = CGPoint(x: size.width / 2, y: size.height / 2)

        guard var ring = ringID.flatMap({ ContextResolver.resolve(ringID: $0, config: config) })
                ?? config.rootRing else { return }
        stack = [ring]
        for _ in 1..<max(depth, 1) {
            let next = ring.activeItems.first { $0.action.kind == .subring }
                .flatMap { ContextResolver.resolve(ringID: $0.action.value, config: config) }
            guard let next else { break }
            stack.append(next)
            ring = next
        }

        self.filter = filter
        self.selection = selection
        isOffscreenRender = true
        presentationProgress = 1
        isVisible = true
    }

    private func warpCursor(to point: CGPoint) {
        // CGWarp uses top-left origin; NSEvent.mouseLocation is bottom-left.
        guard let primary = NSScreen.screens.first else { return }
        let flipped = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        CGWarpMouseCursorPosition(flipped)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

// MARK: - Geometry

enum RingGeometry {

    /// Angle of node `index`, in radians, y-up.
    static func angle(index: Int, layout: RingLayout) -> Double {
        guard layout.count > 0 else { return .pi / 2 }
        return layout.angle(at: index)
    }

    /// Index whose node direction is closest to `vector`.
    static func nearestIndex(to vector: CGPoint, layout: RingLayout) -> Int {
        guard layout.count > 0 else { return 0 }
        let theta = atan2(vector.y, vector.x)
        var best = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for i in 0..<layout.count {
            let delta = abs(shortestAngle(theta - layout.angle(at: i)))
            if delta < bestDelta {
                bestDelta = delta
                best = i
            }
        }
        return best
    }

    static func shortestAngle(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi }
        if x < -.pi { x += 2 * .pi }
        return x
    }

    /// Node position in a y-down view space.
    static func point(index: Int, layout: RingLayout, radius: Double, center: CGPoint) -> CGPoint {
        let a = angle(index: index, layout: layout)
        return CGPoint(x: center.x + radius * cos(a), y: center.y - radius * sin(a))
    }
}
