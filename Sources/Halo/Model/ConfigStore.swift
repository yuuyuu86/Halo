import AppKit
import Combine
import Foundation

/// Single source of truth for the user's rings, persisted as JSON in
/// ~/Library/Application Support/Halo/config.json.
@MainActor
final class ConfigStore: ObservableObject {

    static let shared = ConfigStore()

    @Published var config: HaloConfig {
        didSet { scheduleSave() }
    }

    private var saveWorkItem: DispatchWorkItem?

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Halo", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("config.json")
    }

    private init() {
        if let loaded = Self.load() {
            let migrated = Self.migrate(loaded)
            config = migrated
            // `didSet` does not run during init, so a migration has to persist
            // itself explicitly or it would be redone on every launch. Compare
            // the encoded form rather than the version: the version-independent
            // repairs change the file without moving the version number.
            if Self.encoded(migrated) != Self.encoded(loaded) { save() }
        } else {
            config = DefaultConfig.make()
            // Write the seed config immediately so the file is discoverable.
            save()
        }
    }

    // MARK: - Persistence

    private static func load() -> HaloConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(HaloConfig.self, from: data)
        } catch {
            NSLog("Halo: config.json could not be decoded (%@) — keeping it and starting fresh.",
                  String(describing: error))
            let backup = directoryURL.appendingPathComponent("config.broken-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: backup)
            return nil
        }
    }

    /// Brings older files forward. Sizes are only rewritten when they still hold
    /// the previous defaults — a user who deliberately picked 132pt keeps it.
    nonisolated static func migrate(_ input: HaloConfig) -> HaloConfig {
        var config = input
        if config.version < 2 {
            if config.appearance.ringRadius == 132 { config.appearance.ringRadius = 168 }
            if config.appearance.nodeSize == 46 { config.appearance.nodeSize = 60 }
            if config.appearance.deadZone == 40 { config.appearance.deadZone = 46 }
            config.version = 2
        }
        if config.version < 3 {
            // The AI ring is new. Add it — and a way to reach it — without
            // disturbing anything the user has already arranged.
            if config.ring(withID: DefaultConfig.aiID) == nil {
                config.rings.append(DefaultConfig.ai())
            }
            if let rootIndex = config.rings.firstIndex(where: { $0.id == config.rootRingID }),
               !config.rings[rootIndex].items.contains(where: {
                   $0.action.kind == .subring && $0.action.value == DefaultConfig.aiID
               }) {
                config.rings[rootIndex].items.append(
                    RingItem(title: "AI", glyph: "sparkles",
                             action: .subring(DefaultConfig.aiID)))
            }
            config.version = HaloConfig.currentVersion
        }

        // Version-independent repairs. These run on every load because a
        // configuration can reach an inconsistent state without its version
        // changing — hand-edited files, or a migration that shipped incomplete.
        if !AIConfig.knownProviders.contains(config.ai.provider) {
            config.ai.provider = AIConfig.default.provider
        }
        if config.ai.systemPrompt == Self.retiredSystemPrompt {
            // Untouched prompt from the cloud era: written in English for a
            // different model. A prompt the user wrote is left alone.
            config.ai.systemPrompt = AIConfig.defaultSystemPrompt
        }
        return config
    }

    /// Canonical bytes for a configuration, used to decide whether a load
    /// changed anything worth writing back.
    private static func encoded(_ config: HaloConfig) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(config)
    }

    /// The system prompt shipped before Halo moved to the on-device model.
    private static let retiredSystemPrompt =
        "You are Halo, a concise macOS assistant. Answer with the transformed text only."

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.directoryURL,
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("Halo: failed to save config — %@", String(describing: error))
        }
    }

    // MARK: - Mutations

    func ring(withID id: String) -> Ring? { config.ring(withID: id) }

    func updateRing(_ ring: Ring) {
        guard let index = config.rings.firstIndex(where: { $0.id == ring.id }) else { return }
        config.rings[index] = ring
    }

    @discardableResult
    func addRing(title: String = "新しいリング") -> Ring {
        let ring = Ring(id: "ring." + UUID().uuidString.prefix(8).lowercased(), title: title, items: [])
        config.rings.append(ring)
        return ring
    }

    func deleteRing(id: String) {
        guard id != config.rootRingID else { return }
        config.rings.removeAll { $0.id == id }
        config.contextRules.removeAll { $0.ringID == id }
        // Drop now-dangling sub-ring references.
        for i in config.rings.indices {
            for j in config.rings[i].items.indices
            where config.rings[i].items[j].action.kind == .subring
                && config.rings[i].items[j].action.value == id {
                config.rings[i].items[j].action = .empty
            }
        }
    }

    func resetToDefaults() {
        config = DefaultConfig.make()
        save()
    }

    func revealConfigInFinder() {
        save()
        NSWorkspace.shared.activateFileViewerSelecting([Self.fileURL])
    }
}
