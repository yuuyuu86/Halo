import XCTest
@testable import Halo

/// The angle maths drives both what is drawn and what gets selected, so a sign
/// error here is invisible in code review and obvious the moment you use the
/// app. These cover the layout rules that were actually wrong at some point.
final class RingGeometryTests: XCTestCase {

    private func layout(count: Int,
                        start: Double = 90,
                        sweep: Double = 360,
                        clockwise: Bool = true) -> RingLayout {
        var appearance = Appearance()
        appearance.startAngleDegrees = start
        appearance.sweepDegrees = sweep
        appearance.clockwise = clockwise
        return appearance.layout(count: count)
    }

    private func assertAngle(_ actual: Double, degrees expected: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        let delta = RingGeometry.shortestAngle(actual - expected * .pi / 180)
        XCTAssertEqual(delta, 0, accuracy: 1e-9, file: file, line: line)
    }

    // MARK: Placement

    func testFirstNodeSitsAtTheStartAngle() {
        assertAngle(layout(count: 8).angle(at: 0), degrees: 90)
    }

    func testFullCircleDoesNotPlaceTheLastNodeOnTheFirst() {
        // Eight nodes over 360° must step 45°, not 360/7.
        let l = layout(count: 8)
        assertAngle(l.angle(at: 1), degrees: 45)
        assertAngle(l.angle(at: 7), degrees: 90 - 315)
        XCTAssertNotEqual(RingGeometry.shortestAngle(l.angle(at: 0) - l.angle(at: 7)), 0)
    }

    func testPartialSweepReachesBothEnds() {
        // A 180° fan with 5 nodes should land exactly on 0° and 180° of the fan.
        let l = layout(count: 5, start: 180, sweep: 180)
        assertAngle(l.angle(at: 0), degrees: 180)
        assertAngle(l.angle(at: 4), degrees: 0)
    }

    func testCounterClockwiseReversesTheSweep() {
        assertAngle(layout(count: 4, clockwise: false).angle(at: 1), degrees: 180)
        assertAngle(layout(count: 4, clockwise: true).angle(at: 1), degrees: 0)
    }

    func testSingleNodeSitsAtTheStartAngle() {
        assertAngle(layout(count: 1).angle(at: 0), degrees: 90)
    }

    // MARK: Selection

    func testNearestIndexPicksTheNodeUnderTheCursor() {
        let l = layout(count: 4)          // 上・右・下・左
        XCTAssertEqual(RingGeometry.nearestIndex(to: CGPoint(x: 0, y: 100), layout: l), 0)
        XCTAssertEqual(RingGeometry.nearestIndex(to: CGPoint(x: 100, y: 0), layout: l), 1)
        XCTAssertEqual(RingGeometry.nearestIndex(to: CGPoint(x: 0, y: -100), layout: l), 2)
        XCTAssertEqual(RingGeometry.nearestIndex(to: CGPoint(x: -100, y: 0), layout: l), 3)
    }

    func testNearestIndexIsStableAcrossTheWrapPoint() {
        // Just clockwise of straight up must still be the top node, not the last.
        let l = layout(count: 8)
        let justPastTop = CGPoint(x: sin(0.1) * 100, y: cos(0.1) * 100)
        XCTAssertEqual(RingGeometry.nearestIndex(to: justPastTop, layout: l), 0)
    }

    func testPointMatchesTheAngleInViewCoordinates() {
        // View space is y-down, so the top node must have the smaller y.
        let l = layout(count: 4)
        let center = CGPoint(x: 100, y: 100)
        let top = RingGeometry.point(index: 0, layout: l, radius: 50, center: center)
        XCTAssertEqual(top.x, 100, accuracy: 1e-9)
        XCTAssertEqual(top.y, 50, accuracy: 1e-9)
    }

    func testShortestAngleNormalisesToPlusMinusPi() {
        XCTAssertEqual(RingGeometry.shortestAngle(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(RingGeometry.shortestAngle(2 * .pi + 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(RingGeometry.shortestAngle(-2 * .pi - 0.5), -0.5, accuracy: 1e-9)
        // ±π are the same direction; only the magnitude has to land on the bound.
        XCTAssertEqual(abs(RingGeometry.shortestAngle(3 * .pi)), .pi, accuracy: 1e-9)
        XCTAssertEqual(abs(RingGeometry.shortestAngle(-3 * .pi)), .pi, accuracy: 1e-9)

        for raw in stride(from: -20.0, through: 20.0, by: 0.37) {
            let normalised = RingGeometry.shortestAngle(raw)
            XCTAssertLessThanOrEqual(abs(normalised), Double.pi + 1e-9)
            // Same direction as the input, just wrapped.
            XCTAssertEqual(sin(normalised), sin(raw), accuracy: 1e-9)
            XCTAssertEqual(cos(normalised), cos(raw), accuracy: 1e-9)
        }
    }

    // MARK: Guards

    func testSweepIsClampedToASensibleRange() {
        XCTAssertEqual(layout(count: 4, sweep: 5).sweep, 30 * .pi / 180, accuracy: 1e-9)
        XCTAssertEqual(layout(count: 4, sweep: 999).sweep, 2 * .pi, accuracy: 1e-9)
    }

    func testEmptyRingDoesNotDivideByZero() {
        let l = layout(count: 0)
        XCTAssertEqual(l.step, 0)
        XCTAssertEqual(RingGeometry.nearestIndex(to: CGPoint(x: 1, y: 1), layout: l), 0)
    }
}
