import XCTest
@testable import Halo

/// Config decoding is the one place where a mistake costs the user their work,
/// so these lock in the two promises Halo makes: unknown-key tolerance, and a
/// migration that never overwrites a deliberate choice.
final class ConfigTests: XCTestCase {

    private func decodeConfig(_ json: String) throws -> HaloConfig {
        try JSONDecoder().decode(HaloConfig.self, from: Data(json.utf8))
    }

    // MARK: Forward compatibility

    func testConfigWrittenByAnOlderBuildStillDecodes() throws {
        // A v1 file: no triggers, no nodeShape, no sweepDegrees.
        let json = """
        {
          "version": 1,
          "rootRingID": "halo.root",
          "rings": [{"id": "halo.root", "title": "Halo", "items": []}],
          "contextRules": [],
          "hotKey": {"keyCode": 49, "modifiers": 2048, "enabled": true},
          "appearance": {"ringRadius": 132, "nodeSize": 46, "deadZone": 40,
                         "diveMargin": 56, "accentHex": "#FFC46B",
                         "secondaryHex": "#9B8CFF", "showLabels": true,
                         "stickyThreshold": 0.28, "ascendDwell": 0.25,
                         "animationSpeed": 1},
          "ai": {"enabled": false, "provider": "anthropic", "model": "m",
                 "endpoint": "e", "apiKeyEnvVar": "K", "systemPrompt": "s",
                 "maxTokens": 1024},
          "launchAtLogin": false,
          "clipboardHistoryEnabled": true,
          "clipboardHistoryLimit": 20
        }
        """
        let config = try decodeConfig(json)
        XCTAssertEqual(config.rings.count, 1)
        XCTAssertEqual(config.appearance.ringRadius, 132)
        // Options that did not exist yet fall back to their defaults.
        XCTAssertEqual(config.appearance.nodeShape, .circle)
        XCTAssertEqual(config.appearance.sweepDegrees, 360)
        XCTAssertFalse(config.triggers.doubleTapEnabled)
    }

    func testAlmostEmptyConfigDecodesRatherThanThrowing() throws {
        let config = try decodeConfig("{}")
        XCTAssertTrue(config.rings.isEmpty)
        XCTAssertEqual(config.appearance, .default)
        XCTAssertEqual(config.hotKey, .default)
    }

    func testRetiredShowLabelsFlagBecomesLabelPlacement() throws {
        let hidden = try decodeConfig("""
        {"appearance": {"showLabels": false}}
        """)
        XCTAssertEqual(hidden.appearance.labelPlacement, .hidden)

        // An explicit labelPlacement wins over the legacy flag.
        let explicit = try decodeConfig("""
        {"appearance": {"showLabels": false, "labelPlacement": "inside"}}
        """)
        XCTAssertEqual(explicit.appearance.labelPlacement, .inside)
    }

    func testAppearanceSurvivesAnEncodeDecodeRoundTrip() throws {
        var appearance = Appearance()
        appearance.nodeShape = .hexagon
        appearance.sweepDegrees = 200
        appearance.clockwise = false
        appearance.backdrop = .blur
        appearance.glowIntensity = 1.75
        appearance.haptics = false

        let data = try JSONEncoder().encode(appearance)
        XCTAssertEqual(try JSONDecoder().decode(Appearance.self, from: data), appearance)
    }

    func testWholeConfigSurvivesAnEncodeDecodeRoundTrip() throws {
        var config = HaloConfig()
        config.rings = [Ring(id: "r", title: "R")]
        config.rings[0].hotKey = HotKeyConfig(keyCode: 12, modifiers: 256, enabled: true)
        config.rootRingID = "r"
        config.triggers.doubleTapEnabled = true
        config.triggers.doubleTapModifier = .leftOption
        config.appearance.nodeShape = .diamond

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(HaloConfig.self, from: data)

        XCTAssertEqual(decoded.triggers, config.triggers)
        XCTAssertEqual(decoded.appearance, config.appearance)
        XCTAssertEqual(decoded.rings.first?.hotKey, config.rings.first?.hotKey)
        XCTAssertEqual(decoded.rootRingID, "r")
    }

    func testRingWithoutAHotKeyDecodesAsNil() throws {
        let config = try decodeConfig("""
        {"rings": [{"id": "r", "title": "R", "items": []}]}
        """)
        XCTAssertNil(config.rings.first?.hotKey)
    }

    // MARK: Migration

    func testMigrationEnlargesRingsThatStillHoldTheOldDefaults() {
        var config = HaloConfig()
        config.version = 1
        config.appearance.ringRadius = 132
        config.appearance.nodeSize = 46
        config.appearance.deadZone = 40

        let migrated = ConfigStore.migrate(config)
        XCTAssertEqual(migrated.version, HaloConfig.currentVersion)
        XCTAssertEqual(migrated.appearance.ringRadius, 168)
        XCTAssertEqual(migrated.appearance.nodeSize, 60)
        XCTAssertEqual(migrated.appearance.deadZone, 46)
    }

    func testMigrationLeavesDeliberateSizesAlone() {
        var config = HaloConfig()
        config.version = 1
        config.appearance.ringRadius = 200
        config.appearance.nodeSize = 46      // still a default → should grow

        let migrated = ConfigStore.migrate(config)
        XCTAssertEqual(migrated.appearance.ringRadius, 200)
        XCTAssertEqual(migrated.appearance.nodeSize, 60)
    }

    func testMigrationIsIdempotent() {
        var config = HaloConfig()
        config.version = 1
        config.appearance.ringRadius = 132

        let once = ConfigStore.migrate(config)
        let twice = ConfigStore.migrate(once)
        XCTAssertEqual(twice.version, HaloConfig.currentVersion)
        XCTAssertEqual(twice.appearance.ringRadius, once.appearance.ringRadius)
    }

    // MARK: Rings

    func testActiveItemsExcludesDisabledOnes() {
        var ring = Ring(title: "t")
        ring.items = [RingItem(title: "a"),
                      RingItem(title: "b", enabled: false),
                      RingItem(title: "c")]
        XCTAssertEqual(ring.activeItems.map(\.title), ["a", "c"])
    }

    func testItemFallsBackToItsActionGlyph() {
        let item = RingItem(title: "t", glyph: "", action: .url("https://example.com"))
        XCTAssertEqual(item.effectiveGlyph, ActionKind.openURL.symbol)

        let custom = RingItem(title: "t", glyph: "bolt.fill", action: .url("https://example.com"))
        XCTAssertEqual(custom.effectiveGlyph, "bolt.fill")
    }

    func testDefaultConfigIsInternallyConsistent() {
        let config = DefaultConfig.make()
        XCTAssertNotNil(config.rootRing, "ルートリングが解決できること")

        let ringIDs = Set(config.rings.map(\.id))
        for ring in config.rings {
            for item in ring.items where item.action.kind == .subring {
                let target = item.action.value
                XCTAssertTrue(ringIDs.contains(target) || DynamicRing(rawValue: target) != nil,
                              "\(ring.title) の「\(item.title)」が存在しないリング \(target) を指しています")
            }
        }
        for rule in config.contextRules {
            XCTAssertTrue(ringIDs.contains(rule.ringID),
                          "コンテキストルール \(rule.bundleIdentifier) の参照先がありません")
        }
    }
}

/// Structural guards on ring graphs. A configuration the user can build in the
/// editor — including one that points at itself — must not be able to make the
/// ring stack grow without bound.
final class RingGraphTests: XCTestCase {

    func testStackDepthHasACeiling() {
        XCTAssertGreaterThan(RingController.maximumDepth, 1)
        XCTAssertLessThanOrEqual(RingController.maximumDepth, 10,
                                 "深すぎる階層はエコーリングが潰れて読めなくなる")
    }

    func testDefaultRingsNestWellWithinTheCeiling() {
        let config = DefaultConfig.make()

        /// Longest sub-ring chain reachable from the root, cycle-safe.
        func depth(of ringID: String, seen: Set<String>) -> Int {
            guard !seen.contains(ringID), let ring = config.ring(withID: ringID) else { return 0 }
            let next = seen.union([ringID])
            let children = ring.activeItems
                .filter { $0.action.kind == .subring }
                .map { depth(of: $0.action.value, seen: next) }
            return 1 + (children.max() ?? 0)
        }

        let deepest = depth(of: config.rootRingID, seen: [])
        XCTAssertLessThanOrEqual(deepest, RingController.maximumDepth,
                                 "既定のリングだけで上限に触れてはいけない")
    }

    func testARingMayReferenceItselfWithoutTheConfigBeingRejected() {
        // The editor allows it; the controller is what refuses to act on it.
        var ring = Ring(id: "loop", title: "ループ")
        ring.items = [RingItem(title: "自分", action: .subring("loop"))]
        var config = HaloConfig()
        config.rings = [ring]
        config.rootRingID = "loop"

        let cleaned = ConfigTransfer.sanitised(config)
        XCTAssertEqual(cleaned.rings[0].items[0].action.kind, .subring,
                       "自己参照は「壊れた参照」ではないので残る")
    }
}
