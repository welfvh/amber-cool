// TempLoop — stateful side of the hold-temp control loop (pure curve math lives in FanCurve).
// In the library, behind the FanControlling seam, so the state machine is unit-testable.

import Foundation

/// The slice of SMC the control loop drives. SMC conforms below; tests substitute a mock.
public protocol FanControlling {
    func controlTemperature(_ spec: String) -> Double?
    func cpuTemperature() -> Double?
    func fans() -> [FanInfo]
    @discardableResult func setTarget(_ i: Int, rpm: Double) -> Bool
    @discardableResult func applyMax() -> Bool
}

extension SMC: FanControlling {}

/// State for the hold-temp loop: smoothed reading + last commanded demand (for slew limiting).
/// Reset on mode change or after a long gap (sleep) so stale state never drives the fans.
/// Curve math lives in FanCurve: smoothstep setpoint ramp merged with a graded die-protection
/// ramp — the die emergency is a curve now, not an on/off cliff at 95°C.
public final class TempLoop {
    /// Skip target writes smaller than this (kills sub-audible dither).
    public static let writeDeadbandRPM = 30.0

    public private(set) var smoothed: Double?
    private(set) var demand: Double?
    public private(set) var envelope: Double?
    private var lastTick: Date?
    /// Injectable clock — the sleep-gap reset must be testable without waiting 60 s.
    var now: () -> Date = { Date() }

    public init() {}

    // Envelope resets too: it re-seeds at the current die on the next tick, so a still-hot
    // machine re-arms instantly while a cooled-down one (post-sleep) starts disarmed.
    public func reset() { smoothed = nil; demand = nil; envelope = nil; lastTick = nil }

    public func tick(_ smc: FanControlling, setpoint: Double, location: String, margin: Double) {
        // 60 s: only a real sleep gap resets. Load-induced loop stalls (SMC calls blocking for
        // 10-20 s under a pegged CPU) must NOT dump the slew state — that reads as a step change.
        if let last = lastTick, now().timeIntervalSince(last) > 60 { reset() }
        lastTick = now()
        guard let raw = smc.controlTemperature(location) else {
            _ = smc.applyMax(); demand = 1; return   // fail-safe: cool hard
        }
        smoothed = smoothed == nil ? raw : (smoothed! * 0.7 + raw * 0.3)
        let die = smc.cpuTemperature()
        envelope = FanCurve.advanceEnvelope(envelope, die: die)
        let d = FanCurve.demand(temp: smoothed!, die: die,
                                setpoint: setpoint, margin: margin, previous: demand,
                                envelope: envelope)
        demand = d
        for f in smc.fans() {
            let rpm = f.min + (f.max - f.min) * d
            if abs(rpm - f.target) >= Self.writeDeadbandRPM { _ = smc.setTarget(f.index, rpm: rpm) }
        }
    }
}
