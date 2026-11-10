import AppKit
import Combine

/// Polls the general pasteboard and keeps a short rolling history so the
/// clipboard sub-ring has something to show. Text only, kept in memory.
@MainActor
final class ClipboardHistory: ObservableObject {

    static let shared = ClipboardHistory()

    struct Entry: Identifiable, Hashable {
        let id = UUID()
        let text: String
        let date: Date

        /// One-line form used as a ring item label.
        var preview: String {
            let flat = text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.count > 28 ? String(flat.prefix(28)) + "…" : flat
        }
    }

    @Published private(set) var entries: [Entry] = []

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var limit: Int { ConfigStore.shared.config.clipboardHistoryLimit }

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.7, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardHistory.shared.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard ConfigStore.shared.config.clipboardHistoryEnabled else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // Respect apps that mark their contents as transient or confidential
        // (password managers set org.nspasteboard.ConcealedType).
        let types = pasteboard.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ||
            types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) {
            return
        }

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        entries.removeAll { $0.text == text }
        entries.insert(Entry(text: text, date: Date()), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    /// Skips the next pasteboard change. Used when Halo itself put the previous
    /// contents back after borrowing the pasteboard.
    func ignoreNextChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func clear() {
        entries.removeAll()
    }

    /// Puts a string on the pasteboard without it bouncing back into history.
    func put(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        entries.removeAll { $0.text == text }
        entries.insert(Entry(text: text, date: Date()), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    var current: String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }
}
