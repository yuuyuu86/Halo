import XCTest
@testable import Halo

/// Confirmation guards and the action model. These are the paths where a wrong
/// default is expensive: an irreversible operation that runs without asking.
final class ActionTests: XCTestCase {

    func testIrreversibleSystemOpsAreMarkedDestructive() {
        XCTAssertTrue(SystemOp.emptyTrash.isDestructive)
        XCTAssertTrue(SystemOp.quitFrontmostApp.isDestructive)
        XCTAssertFalse(SystemOp.screenshotArea.isDestructive)
        XCTAssertFalse(SystemOp.volumeUp.isDestructive)
        XCTAssertFalse(SystemOp.haloPreferences.isDestructive)
    }

    func testDestructiveSystemActionsArmTheGuardWhenBuilt() {
        XCTAssertTrue(HaloAction.system(.emptyTrash).confirm)
        XCTAssertTrue(HaloAction.system(.quitFrontmostApp).confirm)
        XCTAssertFalse(HaloAction.system(.lockScreen).confirm)
    }

    func testUnguardedActionsHaveNoPrompt() {
        XCTAssertNil(HaloAction.app("/Applications/Safari.app").confirmationPrompt)
        XCTAssertNil(HaloAction.system(.lockScreen).confirmationPrompt)
    }

    func testGuardedActionsDescribeThemselves() {
        let prompt = HaloAction.system(.emptyTrash).confirmationPrompt
        XCTAssertEqual(prompt?.title, SystemOp.emptyTrash.displayName)
        XCTAssertFalse(prompt?.detail.isEmpty ?? true)

        var script = HaloAction.script("rm -rf ~/tmp")
        script.confirm = true
        XCTAssertEqual(script.confirmationPrompt?.detail, "rm -rf ~/tmp")
    }

    func testDefaultRingsGuardEveryDestructiveAction() {
        for ring in DefaultConfig.make().rings {
            for item in ring.items where item.action.kind == .system {
                guard let op = SystemOp(rawValue: item.action.value), op.isDestructive else { continue }
                XCTAssertTrue(item.action.confirm,
                              "「\(item.title)」は確認なしで実行されます")
            }
        }
    }

    // MARK: Decoding

    func testActionWrittenBeforeTheConfirmFlagDecodes() throws {
        let json = """
        {"kind": "system", "value": "emptyTrash", "argument": "", "sink": "discard"}
        """
        let action = try JSONDecoder().decode(HaloAction.self, from: Data(json.utf8))
        XCTAssertEqual(action.kind, .system)
        XCTAssertFalse(action.confirm, "無い項目は既定値になること")
    }

    func testActionRoundTripsThroughJSON() throws {
        var action = HaloAction.script("echo hi", sink: .clipboard)
        action.confirm = true
        action.argument = "clipboard"

        let data = try JSONEncoder().encode(action)
        XCTAssertEqual(try JSONDecoder().decode(HaloAction.self, from: data), action)
    }

    func testEmptyActionDecodesFromAnEmptyObject() throws {
        let action = try JSONDecoder().decode(HaloAction.self, from: Data("{}".utf8))
        XCTAssertEqual(action, .empty)
    }
}

/// The ring filter reorders and shrinks the list the whole interaction indexes
/// into, so the invariants around it are worth stating explicitly.
final class RingFilterTests: XCTestCase {

    private func ring(_ titles: [String]) -> Ring {
        Ring(id: "r", title: "R", items: titles.map { RingItem(title: $0) })
    }

    private func filtered(_ ring: Ring, by query: String) -> [RingItem] {
        // Mirrors RingController.visibleItems.
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ring.activeItems }
        return ring.activeItems.filter { $0.title.lowercased().contains(q) }
    }

    func testFilterMatchesAnywhereInTheTitle() {
        let r = ring(["Safari", "Mail", "Terminal"])
        XCTAssertEqual(filtered(r, by: "ai").map(\.title), ["Mail"])
        XCTAssertEqual(filtered(r, by: "rm").map(\.title), ["Terminal"])
    }

    func testFilterIgnoresCase() {
        let r = ring(["Safari", "Xcode"])
        XCTAssertEqual(filtered(r, by: "SAFARI").map(\.title), ["Safari"])
        XCTAssertEqual(filtered(r, by: "xCoDe").map(\.title), ["Xcode"])
    }

    func testEmptyFilterKeepsEveryActiveItem() {
        var r = ring(["a", "b", "c"])
        r.items[1].enabled = false
        XCTAssertEqual(filtered(r, by: "").map(\.title), ["a", "c"])
        XCTAssertEqual(filtered(r, by: "   ").map(\.title), ["a", "c"])
    }

    func testFilterNeverResurrectsDisabledItems() {
        var r = ring(["alpha", "beta"])
        r.items[1].enabled = false
        XCTAssertTrue(filtered(r, by: "beta").isEmpty)
    }

    func testNoMatchesYieldsAnEmptyRingRatherThanEverything() {
        XCTAssertTrue(filtered(ring(["a", "b"]), by: "zzz").isEmpty)
    }
}
