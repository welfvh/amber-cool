import XCTest
@testable import AmberCoolSMC

final class FanCurveTests: XCTestCase {

    // temp 37 skin, default margin 3 — Welf's daily mode
    let sp = 37.0, m = 3.0

    func testSmoothstepEndpoints() {
        XCTAssertEqual(FanCurve.smoothstep(-1), 0)
        XCTAssertEqual(FanCurve.smoothstep(0), 0)
        XCTAssertEqual(FanCurve.smoothstep(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(FanCurve.smoothstep(1), 1)
        XCTAssertEqual(FanCurve.smoothstep(2), 1)
    }

    func testQuietBelowRampFullAbove() {
        XCTAssertEqual(FanCurve.demand(temp: 30, die: 60, setpoint: sp, margin: m, previous: nil), 0)
        XCTAssertEqual(FanCurve.demand(temp: 45, die: 60, setpoint: sp, margin: m, previous: nil), 1)
    }

    func testSoftTakeoffNearThreshold() {
        // 0.5°C past the ramp edge (old linear curve: 8.3% of full range) → gentle now
        let d = FanCurve.demand(temp: sp - m + 0.5, die: 60, setpoint: sp, margin: m, previous: nil)
        XCTAssertLessThan(d, 0.03)
        XCTAssertGreaterThan(d, 0)
    }

    func testMonotonicInTemp() {
        var last = -1.0
        for t in stride(from: 30.0, through: 45.0, by: 0.25) {
            let d = FanCurve.demand(temp: t, die: 60, setpoint: sp, margin: m, previous: nil)
            XCTAssertGreaterThanOrEqual(d, last)
            last = d
        }
    }

    func testNoCliffAtEmergency() {
        // The old code stepped from ramp-value to 1.0 exactly at 95°. The curve must be
        // continuous there: just-below and at-threshold demands agree to <1%.
        let below = FanCurve.demand(temp: 30, die: FanCurve.emergencyC - 0.01, setpoint: sp, margin: m, previous: nil)
        let at = FanCurve.demand(temp: 30, die: FanCurve.emergencyC, setpoint: sp, margin: m, previous: nil)
        XCTAssertEqual(below, at, accuracy: 0.01)
        XCTAssertEqual(at, 1)
    }

    func testDieProtectionBlendsIn() {
        let d92 = FanCurve.demand(temp: 30, die: 92, setpoint: sp, margin: m, previous: nil)
        XCTAssertGreaterThan(d92, 0)   // protection active below the hard threshold
        XCTAssertLessThan(d92, 1)      // but not pinned
    }

    func testSlewLimitsBothDirections() {
        // cold → hot: climb capped per tick
        let up = FanCurve.demand(temp: 45, die: 60, setpoint: sp, margin: m, previous: 0)
        XCTAssertEqual(up, FanCurve.slewUpPerTick, accuracy: 1e-9)
        // hot → cold: descent capped per tick (no slam-down)
        let down = FanCurve.demand(temp: 30, die: 60, setpoint: sp, margin: m, previous: 1)
        XCTAssertEqual(down, 1 - FanCurve.slewDownPerTick, accuracy: 1e-9)
    }

    func testHardEmergencyClimbsAtFastSlew() {
        // die at the hard threshold: not an instant pin, but the fast emergency ramp —
        // full blast within 4 ticks (~8 s) from silence
        var d: Double? = 0
        var ticks = 0
        while d! < 1 {
            d = FanCurve.demand(temp: 30, die: FanCurve.emergencyC, setpoint: sp, margin: m, previous: d)
            ticks += 1
            XCTAssertLessThan(ticks, 5)
        }
        XCTAssertEqual(ticks, 4)
        // and each step is bounded by the emergency up-slew
        let first = FanCurve.demand(temp: 30, die: FanCurve.emergencyC, setpoint: sp, margin: m, previous: 0)
        XCTAssertEqual(first, FanCurve.slewUpEmergencyPerTick, accuracy: 1e-9)
    }

    func testSlewInactiveWithoutPrevious() {
        let d = FanCurve.demand(temp: 45, die: 60, setpoint: sp, margin: m, previous: nil)
        XCTAssertEqual(d, 1)
    }

    func testEnvelopeSeedsAndRateLimits() {
        XCTAssertNil(FanCurve.advanceEnvelope(nil, die: nil))
        XCTAssertEqual(FanCurve.advanceEnvelope(nil, die: 92), 92)          // seeds at current die
        XCTAssertEqual(FanCurve.advanceEnvelope(90, die: 101)!, 90 + FanCurve.envelopeRiseCPerTick)
        XCTAssertEqual(FanCurve.advanceEnvelope(93, die: 60)!, 93 - FanCurve.envelopeFallCPerTick)
        XCTAssertEqual(FanCurve.advanceEnvelope(90, die: nil), 90)          // holds through lost reading
        XCTAssertEqual(FanCurve.advanceEnvelope(90, die: 90.2), 90.2)       // small moves track exactly
    }

    func testEnvelopeFloorHoldsFansThroughValleys() {
        // hot session (envelope armed at 93), die momentarily dips to 85, hands cool:
        // without the floor demand would glide toward 0 — with it, fans hold at the floor
        let d = FanCurve.demand(temp: 30, die: 85, setpoint: sp, margin: m,
                                previous: FanCurve.envelopeFloorMax, envelope: 93)
        XCTAssertEqual(d, FanCurve.envelopeFloorMax, accuracy: 1e-9)
        // disarmed envelope → floor off, old behavior intact
        XCTAssertEqual(FanCurve.envelopeFloor(FanCurve.envelopeStartC), 0)
        XCTAssertEqual(FanCurve.envelopeFloor(nil), 0)
        // protection and emergency still rise above the floor
        XCTAssertEqual(FanCurve.demand(temp: 30, die: 96, setpoint: sp, margin: m,
                                       previous: 1, envelope: 93), 1)
    }

    func testNegativeMarginNeverInvertsCurve() {
        // config typo "temp 37 skin -3": unclamped, (45-40)/(2*-3) → 0 and a hot machine idles
        // its fans. The margin floor must keep hot = max, cold = quiet.
        XCTAssertEqual(FanCurve.demand(temp: 45, die: 60, setpoint: sp, margin: -3, previous: nil), 1)
        XCTAssertEqual(FanCurve.demand(temp: 30, die: 60, setpoint: sp, margin: -3, previous: nil), 0)
        XCTAssertEqual(FanCurve.demand(temp: 45, die: 60, setpoint: sp, margin: 0, previous: nil), 1)
    }
}
