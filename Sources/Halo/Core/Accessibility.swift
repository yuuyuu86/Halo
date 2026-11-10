import AppKit

/// VoiceOver support for the parts of Halo that are not ordinary controls.
///
/// The ring is a transparent overlay with no focusable views, so nothing about
/// it reaches VoiceOver on its own: the ring appears, the selection moves, and
/// a screen reader user hears silence. Announcements fill that gap, and the
/// nodes carry labels so the rotor can reach them.
@MainActor
enum Announcer {

    /// Whether it is worth building announcement strings at all.
    static var isScreenReaderRunning: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
    }

    /// Speaks a string. High priority interrupts, which is what selection
    /// changes need — otherwise the queue lags behind the cursor.
    static func announce(_ message: String, interrupts: Bool = true) {
        guard isScreenReaderRunning, !message.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: (interrupts ? NSAccessibilityPriorityLevel.high
                                       : .medium).rawValue
            ])
    }

    /// "Halo, 8 項目, 開発 を選択中" — enough to orient without the screen.
    static func announceRing(_ ring: Ring?, itemCount: Int, depth: Int) {
        guard isScreenReaderRunning, let ring else { return }
        var parts = [ring.title, "\(itemCount) 項目"]
        if depth > 1 { parts.append("\(depth) 階層目") }
        announce(parts.joined(separator: "、"))
    }

    static func announceSelection(_ item: RingItem?, index: Int, of count: Int) {
        guard isScreenReaderRunning else { return }
        guard let item else {
            announce(String(localized: "選択なし"))
            return
        }
        announce("\(item.title)、\(index + 1) / \(count)")
    }
}
