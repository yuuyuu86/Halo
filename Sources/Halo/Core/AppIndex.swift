import AppKit

/// Lightweight lookup of installed applications, plus an icon cache so the
/// ring can render real app icons without hitting the disk every frame.
enum AppIndex {

    private static let searchRoots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications"
    ]

    /// Full path of an installed .app with the given display name, if present.
    static func path(forAppNamed name: String) -> String? {
        for root in searchRoots {
            let candidate = root + "/" + name + ".app"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Every installed application, sorted by name. Used by the item editor.
    static func allApplications() -> [(name: String, path: String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for root in searchRoots {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let name = String(entry.dropLast(4))
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                result.append((name, root + "/" + entry))
            }
        }
        return result.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            .map { (name: $0.0, path: $0.1) }
    }

    // MARK: - Icons

    private static var iconCache: [String: NSImage] = [:]
    private static let cacheLock = NSLock()

    /// Icon for an item, when one can be resolved from the filesystem or a
    /// running application. Returns nil for items that should draw a glyph.
    static func icon(for action: HaloAction) -> NSImage? {
        switch action.kind {
        case .launchApp:
            return icon(forAppAt: action.value)
        default:
            return nil
        }
    }

    static func icon(forAppAt pathOrBundleID: String) -> NSImage? {
        guard !pathOrBundleID.isEmpty else { return nil }
        cacheLock.lock()
        if let cached = iconCache[pathOrBundleID] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var url: URL?
        if pathOrBundleID.hasPrefix("/") {
            url = URL(fileURLWithPath: pathOrBundleID)
        } else {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pathOrBundleID)
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }

        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 128, height: 128)
        cacheLock.lock()
        iconCache[pathOrBundleID] = image
        cacheLock.unlock()
        return image
    }

    static func displayName(forBundleID id: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }
}
