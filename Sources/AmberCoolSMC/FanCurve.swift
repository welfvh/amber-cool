// FanCurve — pure math for the hold-temp control loop.
//
// Design (2026-07-14, from /usr/local/var/log/amber-cool.log analysis): the old loop was a
// piecewise-LINEAR ramp over setpoint±margin plus a BINARY die emergency (≥95°C → max, <95 →
// straight back). With the die hovering 93–98 under load that cliff slammed the fans between
// ~3500 and 7826 rpm every few ticks (167 jumps ≥2000 rpm in one day). Three changes:
//
//   1. smoothstep instead of linear — no corner at the ramp edges, soft takeoff near threshold.
//   2. die protection is itself a smoothstep ramp (emergencySoftC → emergencyC) merged with the
//      setpoint demand via max(); continuous at the emergency point, so the cliff is gone.
//   3. slew limiting — climb fast, descend gently. A hard emergency (die ≥ emergencyC) bypasses
//      the up-limit so max cooling is still instant; the descent afterwards glides.
public enum FanCurve {

    /// Hard backstop: die at/above this pins fans at max instantly (slew bypassed).
    public static let emergencyC = 95.0
    /// Die protection starts blending in here, reaching full at `emergencyC`.
    public static let emergencySoftC = 90.0
    /// Max demand change per tick, as a fraction of the fan range (~500 rpm up, ~165 rpm down
    /// per 2 s tick on a 5500 rpm span). Asymmetric: heat is urgent, quiet can wait.
    public static let slewUpPerTick = 0.09
    public static let slewDownPerTick = 0.03

    /// Hermite smoothstep, clamped to [0,1]: zero slope at both ends.
    public static func smoothstep(_ x: Double) -> Double {
        let t = Swift.max(0, Swift.min(1, x))
        return t * t * (3 - 2 * t)
    }

    /// Demand for one control tick, as a fraction [0,1] of each fan's [min,max] range.
    /// - temp: smoothed reading at the control location (skin/cpu/sensor)
    /// - die: raw hottest CPU-die reading, if available (drives the protection curve)
    /// - previous: last tick's returned demand; pass nil on the first tick or after a reset
    ///   (mode change, wake from sleep) to jump straight to the computed demand.
    public static func demand(temp: Double, die: Double?, setpoint: Double, margin: Double,
                              previous: Double?) -> Double {
        let want = smoothstep((temp - (setpoint - margin)) / (2 * margin))
        let protect = die.map { smoothstep(($0 - emergencySoftC) / (emergencyC - emergencySoftC)) } ?? 0
        var d = Swift.max(want, protect)
        if let prev = previous, (die ?? 0) < emergencyC {
            d = d > prev ? Swift.min(prev + slewUpPerTick, d)
                         : Swift.max(prev - slewDownPerTick, d)
        }
        return d
    }
}
