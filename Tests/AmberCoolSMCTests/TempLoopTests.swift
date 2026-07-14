import XCTest
@testable import AmberCoolSMC

/// Scripted FanControlling: fixed readings, records every write.
private final class MockFans: FanControlling {
    var controlTemp: Double? = 30
    var die: Double? = 60
    var fan = FanInfo(index: 0, actual: 3000, min: 2000, max: 7000, target: 3000, mode: 1)
    var setTargetCalls: [(index: Int, rpm: Double)] = []
    var applyMaxCalls = 0

    func controlTemperature(_ spec: String) -> Double? { controlTemp }
    func cpuTemperature() -> Double? { die }
    func fans() -> [FanInfo] { [fan] }
    @discardableResult func setTarget(_ i: Int, rpm: Double) -> Bool {
        setTargetCalls.append((i, rpm))
        retarget(rpm)
        return true
    }
    @discardableResult func applyMax() -> Bool { applyMaxCalls += 1; return true }

    func retarget(_ rpm: Double) {
        fan = FanInfo(index: fan.index, actual: fan.actual, min: fan.min, max: fan.max,
                      target: rpm, mode: fan.mode)
    }
}

final class TempLoopTests: XCTestCase {

    // temp 37 skin, margin 3 — same operating point as FanCurveTests
    let sp = 37.0, m = 3.0

    private func tick(_ loop: TempLoop, _ mock: MockFans) {
        loop.tick(mock, setpoint: sp, location: "skin", margin: m)
    }

    func testSensorLossFailSafeThenGlideDown() {
        let mock = MockFans()
        mock.controlTemp = nil
        let loop = TempLoop()
        tick(loop, mock)
        XCTAssertEqual(mock.applyMaxCalls, 1)          // fail-safe: cool hard
        XCTAssertEqual(loop.demand, 1)                 // pinned, so recovery starts from max
        XCTAssertTrue(mock.setTargetCalls.isEmpty)
        // sensor returns cold: descend via slew from the pinned demand, no cliff back down
        mock.controlTemp = 30
        tick(loop, mock)
        XCTAssertEqual(loop.demand!, 1 - FanCurve.slewDownPerTick, accuracy: 1e-9)
    }

    func testWriteDeadband() {
        let mock = MockFans()
        mock.controlTemp = 45                          // demand 1; first tick jumps (no previous)
        let loop = TempLoop()
        tick(loop, mock)
        XCTAssertEqual(mock.setTargetCalls.count, 1)
        XCTAssertEqual(mock.setTargetCalls[0].rpm, 7000, accuracy: 1e-9)
        mock.retarget(6980)                            // within 30 rpm of demand -> skip the write
        tick(loop, mock)
        XCTAssertEqual(mock.setTargetCalls.count, 1)
        mock.retarget(6950)                            // beyond the deadband -> write
        tick(loop, mock)
        XCTAssertEqual(mock.setTargetCalls.count, 2)
    }

    func testSleepGapResetsState() {
        let mock = MockFans()
        let loop = TempLoop()
        var t = Date(timeIntervalSinceReferenceDate: 0)
        loop.now = { t }
        mock.controlTemp = 30
        tick(loop, mock)                               // smoothed 30, demand 0
        t = t.addingTimeInterval(2)
        mock.controlTemp = 60
        tick(loop, mock)                               // hot: climb is slew-limited from 0
        XCTAssertEqual(loop.demand!, FanCurve.slewUpPerTick, accuracy: 1e-9)
        t = t.addingTimeInterval(61)                   // > 60 s gap = sleep, not a loop stall
        tick(loop, mock)                               // reset: no slew from stale demand, EMA restarts
        XCTAssertEqual(loop.demand!, 1)                // jumped straight to computed demand
        XCTAssertEqual(loop.smoothed!, 60)             // raw reading, not blended with stale 39
    }

    func testEMABlendsSecondTick() {
        let mock = MockFans()
        let loop = TempLoop()
        mock.controlTemp = 30
        tick(loop, mock)
        XCTAssertEqual(loop.smoothed!, 30)             // first tick seeds the EMA with raw
        mock.controlTemp = 40
        tick(loop, mock)
        XCTAssertEqual(loop.smoothed!, 30 * 0.7 + 40 * 0.3, accuracy: 1e-9)
    }
}
