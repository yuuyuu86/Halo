import XCTest
@testable import Halo

/// Import and reset both rewrite the user's whole configuration, so the rules
/// they follow are worth pinning down: a merge must not collide with what is
/// already there, and no path may leave a ring pointing at nothing.
final class ConfigTransferTests: XCTestCase {

    private func ring(_ id: String, title: String, items: [RingItem] = []) -> Ring {
        Ring(id: id, title: title, items: items)
    }

    private func subringItem(_ title: String, target: String) -> RingItem {
        RingItem(title: title, action: .subring(target))
    }

    // MARK: - Merge

    func testMergeGivesImportedRingsFreshIDs() {
        var current = HaloConfig()
        current.rings = [ring("shared.id", title: "既存")]
        current.rootRingID = "shared.id"

        let incoming = [ring("shared.id", title: "取り込み")]
        let merged = ConfigTransfer.merge(incoming, into: current)

        XCTAssertEqual(merged.rings.count, 2)
        XCTAssertEqual(merged.rings[0].id, "shared.id", "既存のリングはそのまま")
        XCTAssertNotEqual(merged.rings[1].id, "shared.id", "取り込み側は ID を振り直す")
        XCTAssertEqual(merged.rootRingID, "shared.id", "ルートは動かない")
    }

    func testMergeRewiresSubringReferencesToTheImportedCopies() {
        var current = HaloConfig()
        current.rings = [ring("a", title: "既存の A")]
        current.rootRingID = "a"

        // The incoming set has its own "a", pointed at by its own parent.
        let incoming = [
            ring("parent", title: "親", items: [subringItem("子へ", target: "a")]),
            ring("a", title: "取り込みの A")
        ]
        let merged = ConfigTransfer.merge(incoming, into: current)

        let importedParent = merged.rings.first { $0.title == "親" }
        let importedChild = merged.rings.first { $0.title == "取り込みの A" }
        XCTAssertNotNil(importedParent)
        XCTAssertNotNil(importedChild)
        XCTAssertEqual(importedParent?.items.first?.action.value, importedChild?.id,
                       "取り込んだ親は、取り込んだ子を指すこと（既存の a ではなく）")
        XCTAssertNotEqual(importedParent?.items.first?.action.value, "a")
    }

    func testMergeKeepsDynamicRingReferencesIntact() {
        let incoming = [ring("r", title: "R", items: [
            subringItem("履歴", target: DynamicRing.clipboardHistory.rawValue)
        ])]
        let merged = ConfigTransfer.merge(incoming, into: HaloConfig())
        XCTAssertEqual(merged.rings[0].items[0].action.value,
                       DynamicRing.clipboardHistory.rawValue)
    }

    func testMergeMarksTitlesThatWouldDuplicate() {
        var current = HaloConfig()
        current.rings = [ring("x", title: "開発")]
        let merged = ConfigTransfer.merge([ring("y", title: "開発")], into: current)
        XCTAssertEqual(merged.rings.map(\.title), ["開発", "開発（読み込み）"])
    }

    func testMergeReissuesItemIDs() {
        let item = RingItem(title: "a")
        let merged = ConfigTransfer.merge([ring("r", title: "R", items: [item])],
                                          into: HaloConfig())
        XCTAssertNotEqual(merged.rings[0].items[0].id, item.id)
    }

    func testMergeDropsImportedHotKeys() {
        var incoming = ring("r", title: "R")
        incoming.hotKey = HotKeyConfig()
        let merged = ConfigTransfer.merge([incoming], into: HaloConfig())
        XCTAssertNil(merged.rings[0].hotKey, "他人の環境のキー割り当ては引き継がない")
    }

    // MARK: - Sanitising

    func testSanitisingClearsSubringsThatPointNowhere() {
        var config = HaloConfig()
        config.rings = [ring("r", title: "R", items: [subringItem("迷子", target: "missing")])]
        config.rootRingID = "r"

        let cleaned = ConfigTransfer.sanitised(config)
        XCTAssertEqual(cleaned.rings[0].items[0].action.kind, .none)
    }

    func testSanitisingKeepsValidAndDynamicTargets() {
        var config = HaloConfig()
        config.rings = [
            ring("parent", title: "親", items: [
                subringItem("実在", target: "child"),
                subringItem("動的", target: DynamicRing.runningApps.rawValue)
            ]),
            ring("child", title: "子")
        ]
        config.rootRingID = "parent"

        let cleaned = ConfigTransfer.sanitised(config)
        XCTAssertEqual(cleaned.rings[0].items[0].action.kind, .subring)
        XCTAssertEqual(cleaned.rings[0].items[1].action.kind, .subring)
    }

    func testSanitisingDropsContextRulesForMissingRings() {
        var config = HaloConfig()
        config.rings = [ring("r", title: "R")]
        config.rootRingID = "r"
        config.contextRules = [
            ContextRule(bundleIdentifier: "com.a", ringID: "r"),
            ContextRule(bundleIdentifier: "com.b", ringID: "gone")
        ]

        let cleaned = ConfigTransfer.sanitised(config)
        XCTAssertEqual(cleaned.contextRules.map(\.bundleIdentifier), ["com.a"])
    }

    func testSanitisingRepairsAnUnresolvableRoot() {
        var config = HaloConfig()
        config.rings = [ring("actual", title: "R")]
        config.rootRingID = "does.not.exist"

        // `rootRing` already falls back to the first ring, so the id is only
        // rewritten when nothing at all resolves.
        let cleaned = ConfigTransfer.sanitised(config)
        XCTAssertNotNil(cleaned.rootRing)
    }

    func testSanitisingAnEmptyConfigDoesNotCrash() {
        let cleaned = ConfigTransfer.sanitised(HaloConfig())
        XCTAssertTrue(cleaned.rings.isEmpty)
        XCTAssertNil(cleaned.rootRing)
    }

    // MARK: - Reset scopes

    private func populatedConfig() -> HaloConfig {
        var config = HaloConfig()
        config.rings = [ring("mine", title: "自分のリング")]
        config.rootRingID = "mine"
        config.rings[0].hotKey = HotKeyConfig()
        config.contextRules = [ContextRule(bundleIdentifier: "com.a", ringID: "mine")]
        config.appearance.ringRadius = 999
        config.appearance.nodeShape = .hexagon
        config.hotKey.keyCode = 12
        config.triggers.doubleTapEnabled = true
        config.ai.enabled = true
        config.launchAtLogin = true
        return config
    }

    func testResetAppearanceLeavesRingsAlone() {
        var config = populatedConfig()
        ConfigTransfer.apply(.appearance, to: &config)

        XCTAssertEqual(config.appearance, .default)
        XCTAssertEqual(config.rings.map(\.title), ["自分のリング"])
        XCTAssertEqual(config.hotKey.keyCode, 12)
    }

    func testResetRingsLeavesAppearanceAndHotKeyAlone() {
        var config = populatedConfig()
        ConfigTransfer.apply(.rings, to: &config)

        XCTAssertFalse(config.rings.contains { $0.title == "自分のリング" })
        XCTAssertNotNil(config.rootRing)
        XCTAssertEqual(config.appearance.ringRadius, 999)
        XCTAssertEqual(config.hotKey.keyCode, 12)
        XCTAssertTrue(config.triggers.doubleTapEnabled)
    }

    func testResetTriggersClearsPerRingHotKeysToo() {
        var config = populatedConfig()
        ConfigTransfer.apply(.triggers, to: &config)

        XCTAssertEqual(config.hotKey, .default)
        XCTAssertEqual(config.triggers, .default)
        XCTAssertNil(config.rings[0].hotKey, "リング専用キーも一緒に外れること")
        XCTAssertEqual(config.rings.map(\.title), ["自分のリング"], "リング自体は残ること")
    }

    func testResetContextKeepsTheRingsItPointedAt() {
        var config = populatedConfig()
        ConfigTransfer.apply(.context, to: &config)

        XCTAssertTrue(config.contextRules.isEmpty)
        XCTAssertEqual(config.rings.map(\.title), ["自分のリング"])
    }

    func testResetAILeavesEverythingElse() {
        var config = populatedConfig()
        ConfigTransfer.apply(.ai, to: &config)

        XCTAssertEqual(config.ai, .default)
        XCTAssertFalse(config.ai.enabled)
        XCTAssertEqual(config.appearance.ringRadius, 999)
    }

    func testResetEverythingProducesAUsableConfig() {
        var config = populatedConfig()
        ConfigTransfer.apply(.everything, to: &config)

        XCTAssertEqual(config.appearance, .default)
        XCTAssertEqual(config.hotKey, .default)
        XCTAssertTrue(config.contextRules.allSatisfy { rule in
            config.rings.contains { $0.id == rule.ringID }
        })
        XCTAssertNotNil(config.rootRing)
        XCTAssertFalse(config.rootRing?.activeItems.isEmpty ?? true)
    }

    func testEveryResetScopeLeavesTheConfigSelfConsistent() {
        for scope in ConfigTransfer.ResetScope.allCases {
            var config = populatedConfig()
            ConfigTransfer.apply(scope, to: &config)

            let ringIDs = Set(config.rings.map(\.id))
            for rule in config.contextRules {
                XCTAssertTrue(ringIDs.contains(rule.ringID),
                              "\(scope.rawValue): コンテキストの参照先が消えています")
            }
            for ring in config.rings {
                for item in ring.items where item.action.kind == .subring {
                    XCTAssertTrue(ringIDs.contains(item.action.value)
                                  || DynamicRing(rawValue: item.action.value) != nil,
                                  "\(scope.rawValue): \(item.title) の参照先がありません")
                }
            }
        }
    }
}
