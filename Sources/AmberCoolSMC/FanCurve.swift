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
//   3. slew limiting — climb fast, descend gently. A hard emergency (die ≥ emergencyC) switches
//      to a much faster up-slew (full blast in ~8 s, not one tick); the descent afterwards glides.
public enum FanCurve {

    /// Hard backstop: die at/above this drives demand to max at the emergency up-slew rate.
    public static let emergencyC = 95.0
    /// Die protection starts blending in here, reaching full at `emergencyC`.
    public static let emergencySoftC = 90.0
    /// Max demand change per tick, as a fraction of the fan range (~500 rpm up, ~165 rpm down
    /// per 2 s tick on a 5500 rpm span). Asymmetric: heat is urgent, quiet can wait.
    public static let slewUpPerTick = 0.09
    public static let slewDownPerTick = 0.03
    /// Up-slew while the die is at/above `emergencyC`: much faster than normal but still a ramp —
    /// full blast in ~4 ticks (~8 s) instead of one. The die tolerates transient 95–105°C (it
    /// throttles itself); an instant 0→100% spool-up buys no real safety and sounds like a switch.
    public static let slewUpEmergencyPerTick = 0.25
    /// Smallest usable ramp half-width. A zero or negative margin (user-writable config typo like
    /// "temp 37 skin -3") would invert the ramp — hot readings commanding MINIMUM speed — so the
    /// margin is floored here, at the math layer, protecting every caller.
    public static let minMarginC = 0.5

    /// Sustained-heat floor (proactive cooling). The die under a hot work session oscillates
    /// (89→101°C and back, tens of seconds per swing); chasing it makes the fans cycle, and the
    /// ear keys on that modulation far more than on steady noise. A slow ENVELOPE of die temp
    /// arms a demand floor while the session is hot — fans hold steady through the valleys and
    /// the next spike starts from already-moving air — then decays over ~10 min once work ends.
    /// Rise is rate-limited so a single brief spike (one compile) barely arms it.
    public static let envelopeRiseCPerTick = 0.5   // toward a hotter die: armed after ~1–2 min sustained heat
    public static let envelopeFallCPerTick = 0.03  // decay: ~0.9°C/min, disarms ~10 min after the session
    public static let envelopeStartC = 84.0        // floor begins here…
    public static let envelopeFullC = 93.0         // …tops out here…
    public static let envelopeFloorMax = 0.75      // …below full blast: peaks still stand out of the floor

    /// Advance the die-temp envelope by one tick. Seeds at the current die reading (a daemon
    /// restarted mid-session arms immediately); holds through missing readings.
    public static func advanceEnvelope(_ envelope: Double?, die: Double?) -> Double? {
        guard let die else { return envelope }
        guard let e = envelope else { return die }
        return die > e ? Swift.min(e + envelopeRiseCPerTick, die)
                       : Swift.max(e - envelopeFallCPerTick, die)
    }

    /// Demand floor for a given envelope value.
    public static func envelopeFloor(_ envelope: Double?) -> Double {
        guard let e = envelope else { return 0 }
        return envelopeFloorMax * smoothstep((e - envelopeStartC) / (envelopeFullC - envelopeStartC))
    }

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
    /// - envelope: sustained-heat envelope from `advanceEnvelope` (nil = floor disabled)
    public static func demand(temp: Double, die: Double?, setpoint: Double, margin: Double,
                              previous: Double?, envelope: Double? = nil) -> Double {
        let m = Swift.max(margin, minMarginC)   // never let a bad margin invert the curve
        let want = smoothstep((temp - (setpoint - m)) / (2 * m))
        let protect = die.map { smoothstep(($0 - emergencySoftC) / (emergencyC - emergencySoftC)) } ?? 0
        var d = Swift.max(want, Swift.max(protect, envelopeFloor(envelope)))
        if let prev = previous {
            let upCap = (die ?? 0) >= emergencyC ? slewUpEmergencyPerTick : slewUpPerTick
            d = d > prev ? Swift.min(prev + upCap, d)
                         : Swift.max(prev - slewDownPerTick, d)
        }
        return d
    }
}
