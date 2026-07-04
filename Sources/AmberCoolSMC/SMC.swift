// AmberCoolSMC — shared SMC core for amber-cool.
// Read (unprivileged) + write (root) of AppleSMC keys, plus the Apple Silicon
// Ftst manual-control handshake, fan/temp models, and the three-mode RPM math.
//
// The AppleSMC param struct is exactly 80 bytes. Swift does NOT guarantee C
// struct layout (a mirrored struct mispacks to 76 bytes — the kernel rejects it),
// so we build the 80-byte buffer and poke fields at explicit C offsets.

import Foundation
import IOKit

public struct SMCValue {
    public let type: String   // 4-char data type, e.g. "flt ", "ui8 "
    public let bytes: [UInt8]  // exactly `size` bytes
    public let size: Int
}

public enum FanMode: Int {
    case auto = 0
    case manual = 1
    case system = 3
}

public final class SMC {

    // MARK: - C struct offsets (total 80 bytes)
    private static let STRUCT_SIZE = 80
    private static let OFF_KEY = 0
    private static let OFF_DATASIZE = 28
    private static let OFF_DATATYPE = 32
    private static let OFF_RESULT = 40
    private static let OFF_DATA8 = 42
    private static let OFF_DATA32 = 44
    private static let OFF_BYTES = 48

    private static let KERNEL_INDEX_SMC: UInt32 = 2
    private static let CMD_READ_BYTES: UInt8 = 5
    private static let CMD_WRITE_BYTES: UInt8 = 6
    private static let CMD_READ_INDEX: UInt8 = 8
    private static let CMD_READ_KEYINFO: UInt8 = 9

    private var conn: io_connect_t = 0
    public private(set) var isOpen = false

    public init() {}

    deinit { close() }

    // MARK: - Connection

    @discardableResult
    public func open() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        isOpen = (kr == kIOReturnSuccess)
        return isOpen
    }

    public func close() {
        if isOpen { IOServiceClose(conn); isOpen = false }
    }

    // MARK: - Low-level driver call

    private func call(_ input: [UInt8]) -> (kern_return_t, [UInt8]) {
        var output = [UInt8](repeating: 0, count: Self.STRUCT_SIZE)
        var outSize = Self.STRUCT_SIZE
        let kr = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(conn, Self.KERNEL_INDEX_SMC,
                                          inPtr.baseAddress, Self.STRUCT_SIZE,
                                          outPtr.baseAddress, &outSize)
            }
        }
        return (kr, output)
    }

    private static func fourCharCode(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for c in s.utf8 { r = (r << 8) | UInt32(c) }
        return r
    }
    private static func codeToString(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                 UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? "?"
    }
    private static func setU32(_ buf: inout [UInt8], _ off: Int, _ v: UInt32) {  // native LE on arm64
        buf[off]   = UInt8(v & 0xff)
        buf[off+1] = UInt8((v >> 8) & 0xff)
        buf[off+2] = UInt8((v >> 16) & 0xff)
        buf[off+3] = UInt8((v >> 24) & 0xff)
    }
    private static func getU32(_ buf: [UInt8], _ off: Int) -> UInt32 {
        UInt32(buf[off]) | (UInt32(buf[off+1]) << 8) | (UInt32(buf[off+2]) << 16) | (UInt32(buf[off+3]) << 24)
    }

    private func keyInfo(_ key: String) -> (size: UInt32, type: UInt32)? {
        var inp = [UInt8](repeating: 0, count: Self.STRUCT_SIZE)
        Self.setU32(&inp, Self.OFF_KEY, Self.fourCharCode(key))
        inp[Self.OFF_DATA8] = Self.CMD_READ_KEYINFO
        let (kr, out) = call(inp)
        guard kr == kIOReturnSuccess, out[Self.OFF_RESULT] == 0 else { return nil }
        let size = Self.getU32(out, Self.OFF_DATASIZE)
        let type = Self.getU32(out, Self.OFF_DATATYPE)
        guard size > 0 else { return nil }
        return (size, type)
    }

    // MARK: - Read

    public func read(_ key: String) -> SMCValue? {
        guard isOpen, let info = keyInfo(key) else { return nil }
        var inp = [UInt8](repeating: 0, count: Self.STRUCT_SIZE)
        Self.setU32(&inp, Self.OFF_KEY, Self.fourCharCode(key))
        Self.setU32(&inp, Self.OFF_DATASIZE, info.size)
        inp[Self.OFF_DATA8] = Self.CMD_READ_BYTES
        let (kr, out) = call(inp)
        guard kr == kIOReturnSuccess, out[Self.OFF_RESULT] == 0 else { return nil }
        let n = min(Int(info.size), 32)
        let bytes = Array(out[Self.OFF_BYTES..<(Self.OFF_BYTES + n)])
        return SMCValue(type: Self.codeToString(info.type), bytes: bytes, size: Int(info.size))
    }

    // MARK: - Write (requires root)

    /// Write raw bytes to a key, validating size against the kernel's key info. Returns true on success.
    @discardableResult
    public func writeRaw(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard isOpen, let info = keyInfo(key) else { return false }
        let size = Int(info.size)
        guard size > 0, size <= 32 else { return false }
        var inp = [UInt8](repeating: 0, count: Self.STRUCT_SIZE)
        Self.setU32(&inp, Self.OFF_KEY, Self.fourCharCode(key))
        Self.setU32(&inp, Self.OFF_DATASIZE, info.size)
        inp[Self.OFF_DATA8] = Self.CMD_WRITE_BYTES
        for i in 0..<min(bytes.count, size) { inp[Self.OFF_BYTES + i] = bytes[i] }
        let (kr, out) = call(inp)
        return kr == kIOReturnSuccess && out[Self.OFF_RESULT] == 0
    }

    /// Write a numeric value, encoding it to the key's native SMC data type.
    @discardableResult
    public func writeNumber(_ key: String, _ value: Double) -> Bool {
        guard let info = keyInfo(key) else { return false }
        let type = Self.codeToString(info.type)
        let bytes = Self.encode(value, type: type)
        guard !bytes.isEmpty else { return false }
        return writeRaw(key, bytes)
    }

    // MARK: - Decode / encode

    public static func decode(_ v: SMCValue) -> Double? {
        switch v.type {
        case "flt ": guard v.bytes.count >= 4 else { return nil }
            return Double(v.bytes.withUnsafeBytes { $0.load(as: Float32.self) })  // little-endian
        case "fpe2": guard v.bytes.count >= 2 else { return nil }
            return Double((UInt16(v.bytes[0]) << 8) | UInt16(v.bytes[1])) / 4.0
        case "fp78": guard v.bytes.count >= 2 else { return nil }
            return Double((UInt16(v.bytes[0]) << 8) | UInt16(v.bytes[1])) / 256.0
        case "sp78": guard v.bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(v.bytes[0]) << 8) | UInt16(v.bytes[1]))
            return Double(raw) / 256.0
        case "ui8 ", "si8 ": guard v.bytes.count >= 1 else { return nil }
            return Double(v.bytes[0])
        case "ui16": guard v.bytes.count >= 2 else { return nil }
            return Double((UInt16(v.bytes[0]) << 8) | UInt16(v.bytes[1]))
        default: return nil
        }
    }

    private static func encode(_ value: Double, type: String) -> [UInt8] {
        switch type {
        case "flt ":
            var f = Float32(value)
            return withUnsafeBytes(of: &f) { Array($0) }  // little-endian on arm64
        case "fpe2":
            let raw = UInt16(max(0, min(Double(UInt16.max), (value * 4).rounded())))
            return [UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        case "ui8 ", "si8 ":
            return [UInt8(max(0, min(255, value.rounded())))]
        case "ui16":
            let raw = UInt16(max(0, min(Double(UInt16.max), value.rounded())))
            return [UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        default:
            return []
        }
    }

    public func value(_ key: String) -> Double? {
        guard let v = read(key) else { return nil }
        return Self.decode(v)
    }
}

// MARK: - Fan model & control

public struct FanInfo {
    public let index: Int
    public let actual: Double
    public let min: Double
    public let max: Double
    public let target: Double
    public let mode: Int
}

public extension SMC {

    var fanCount: Int { Int(value("FNum") ?? 0) }

    func fan(_ i: Int) -> FanInfo? {
        guard let ac = value("F\(i)Ac"), let mn = value("F\(i)Mn"),
              let mx = value("F\(i)Mx") else { return nil }
        let tg = value("F\(i)Tg") ?? ac
        let md = Int(value("F\(i)Md") ?? value("F\(i)md") ?? 0)
        return FanInfo(index: i, actual: ac, min: mn, max: mx, target: tg, mode: md)
    }

    func fans() -> [FanInfo] { (0..<fanCount).compactMap { fan($0) } }

    /// True if Ftst exists on this machine (Apple Silicon manual unlock key).
    var hasFtst: Bool { read("Ftst") != nil }

    /// Take manual control of all fans. On Apple Silicon, performs the Ftst handshake:
    /// write Ftst=1, wait for F0Md to drop 3->0, then set each F{i}Md=1.
    /// Returns true if all fans ended in manual mode.
    @discardableResult
    func engageManual(timeout: TimeInterval = 10, poll: TimeInterval = 0.1) -> Bool {
        let count = fanCount
        guard count > 0 else { return false }

        if hasFtst {
            writeNumber("Ftst", 1)
            // Wait for thermalmonitord to relinquish (F0Md transitions 3 -> 0).
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let md = Int(value("F0Md") ?? value("F0md") ?? 3)
                if md != 3 { break }
                Thread.sleep(forTimeInterval: poll)
            }
        }

        var ok = true
        for i in 0..<count {
            // Probe both casings; use whichever key exists.
            if read("F\(i)Md") != nil {
                if !writeNumber("F\(i)Md", 1) { ok = false }
            } else if read("F\(i)md") != nil {
                if !writeNumber("F\(i)md", 1) { ok = false }
            } else {
                ok = false
            }
        }
        return ok
    }

    /// Set a fan's target RPM (clamped to its [min,max]). Caller must engageManual() first.
    @discardableResult
    func setTarget(_ i: Int, rpm: Double) -> Bool {
        guard let f = fan(i) else { return false }
        let clamped = Swift.max(f.min, Swift.min(f.max, rpm))
        return writeNumber("F\(i)Tg", clamped)
    }

    /// Absolute lower bound for the scale's quiet end. The fan's reported min (F0Mn, ~2317 on this
    /// M4 Pro) is just a guideline — writing a lower target makes the fans genuinely quieter. We
    /// floor at 1500 rpm so the fan never stalls (a stalled fan can't be trusted to restart on demand).
    static let scaleFloorRPM: Double = 1500

    /// Mode 1: scale 0...10 -> target between `scaleFloorRPM` (quieter than the reported min) and max.
    @discardableResult
    func applyScale(_ scale: Double) -> Bool {
        let s = Swift.max(0, Swift.min(10, scale)) / 10.0
        var ok = true
        for f in fans() {
            let lo = Swift.min(Self.scaleFloorRPM, f.min)        // allow below the reported min
            let target = lo + (f.max - lo) * s
            let clamped = Swift.max(lo, Swift.min(f.max, target)) // bypass setTarget's [min,max] clamp
            if !writeNumber("F\(f.index)Tg", clamped) { ok = false }
        }
        return ok
    }

    /// Mode 2: explicit RPM on all fans (clamped per fan).
    @discardableResult
    func applyRPM(_ rpm: Double) -> Bool {
        var ok = true
        for f in fans() { if !setTarget(f.index, rpm: rpm) { ok = false } }
        return ok
    }

    /// Convenience: full blast.
    @discardableResult
    func applyMax() -> Bool { applyScale(10) }

    /// Restore macOS automatic fan control. On Apple Silicon, clears Ftst so
    /// thermalmonitord reclaims (fans return to System Mode 3).
    @discardableResult
    func restoreAuto() -> Bool {
        var ok = true
        for i in 0..<fanCount {
            if read("F\(i)Md") != nil { if !writeNumber("F\(i)Md", 0) { ok = false } }
            else if read("F\(i)md") != nil { if !writeNumber("F\(i)md", 0) { ok = false } }
        }
        if hasFtst { if !writeNumber("Ftst", 0) { ok = false } }
        return ok
    }
}

// MARK: - Temperature model

public extension SMC {

    /// CPU cluster die sensors (flt), VALIDATED on M4 Pro (these 11 read ~64–77°C under load;
    /// other sampled keys returned nil or bogus values). Key names are chip-specific and are
    /// REUSED across generations with different meanings, so do NOT blindly add other-gen keys —
    /// that pollutes the average (observed: adding M1–M3 keys dropped the reading to a bogus 16°C).
    /// Other chips need their own validated set (or full key enumeration + filtering).
    static let cpuTempKeys: [String] = [
        "Te05","Te0S","Tp01","Tp05","Tp09","Tp0D","Tp0H","Tp0e","Tp0A","Tp0C","Tp0f"
    ]

    /// Per-sensor readings for the valid CPU cluster keys (for logging/diagnostics).
    func cpuTemperatureSamples() -> [(key: String, value: Double)] {
        var out: [(String, Double)] = []
        var seen = Set<String>()
        for k in Self.cpuTempKeys where !seen.contains(k) {
            seen.insert(k)
            if let d = value(k), d > 0, d < 150 { out.append((k, d)) }
        }
        return out
    }

    /// CPU temperature for control = the HOTTEST valid cluster sensor.
    /// Averaging is wrong on Apple Silicon: idle/clock-gated P-core sensors report
    /// ~0 / negative values, which tank an average to a bogus low (observed: 15°C while
    /// the hottest core was 57°C). The max sensor is both robust to that and the correct
    /// thermal control input (cool to the hottest point). Matches TG Pro "Highest CPU".
    func cpuTemperature() -> Double? {
        cpuTemperatureSamples().map { $0.value }.max()
    }
}

// MARK: - Full sensor enumeration (discover every temperature sensor on this machine)

public struct TempSensor {
    public let key: String
    public let value: Double
    /// Coarse classification by key prefix + value range.
    /// .die = CPU/GPU silicon (hot, 50–90°C); .skin = chassis/surface near hands (warm, ~25–45°C);
    /// .other = battery/ambient/power/unknown.
    public enum Kind: String { case die, skin, other }
    public let kind: Kind
}

public extension SMC {

    /// Surface / hand-contact sensors — what your palms, wrists and fingers actually feel,
    /// NOT the silicon die. Validated present + sane (~32–36°C) on this M4 Pro:
    ///   TaLW/TaRW = ambient Left/Right Wrist (the palm rest)
    ///   Ts0P/Ts1P = Apple "skin" sensors (external case temp; drive thermal-comfort limits)
    ///   TB0T/TB1T/TB2T = battery, which sits directly under the trackpad/palm rest
    /// "Hold temperature → Hands" controls toward the HOTTEST of these (the warmest spot you touch).
    static let skinTempKeys: [String] = [
        "TaLW","TaRW","Ts0P","Ts1P","TB0T","TB1T","TB2T"
    ]

    /// Number of SMC keys the kernel exposes (read the "#KEY" count key, a 4-byte big-endian int).
    var keyCount: Int {
        guard let v = read("#KEY"), v.bytes.count >= 4 else { return 0 }
        let b = v.bytes
        return Int((UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3]))
    }

    /// Resolve the 4-char key name at a given enumeration index (CMD_READ_INDEX / data32 = index).
    func keyName(at index: Int) -> String? {
        guard isOpen else { return nil }
        var inp = [UInt8](repeating: 0, count: Self.STRUCT_SIZE)
        inp[Self.OFF_DATA8] = Self.CMD_READ_INDEX
        Self.setU32(&inp, Self.OFF_DATA32, UInt32(index))
        let (kr, out) = call(inp)
        guard kr == kIOReturnSuccess else { return nil }
        let code = Self.getU32(out, Self.OFF_KEY)
        guard code != 0 else { return nil }
        return Self.codeToString(code)
    }

    /// Every key name the SMC exposes (one IOKit call per index; ~hundreds total).
    func allKeyNames() -> [String] {
        let n = keyCount
        guard n > 0 else { return [] }
        var out: [String] = []
        out.reserveCapacity(n)
        for i in 0..<n { if let k = keyName(at: i) { out.append(k) } }
        return out
    }

    /// All temperature sensors (keys starting with "T") that read a plausible value,
    /// classified into die / skin / other. The classification is a heuristic: it's how we
    /// surface "heat near your hands" without a documented per-model sensor map.
    func allTemperatureSensors() -> [TempSensor] {
        let skinSet = Set(Self.skinTempKeys)
        var out: [TempSensor] = []
        for k in allKeyNames() where k.hasPrefix("T") {
            guard let d = value(k), d > 0, d < 150 else { continue }
            let kind: TempSensor.Kind
            if skinSet.contains(k) {
                kind = .skin                                  // curated surface/hand-contact sensors
            } else if k.hasPrefix("Tp") || k.hasPrefix("Te") || k.hasPrefix("Tg") {
                kind = .die                                   // CPU/GPU silicon
            } else {
                kind = .other                                 // internal proximities, battery, ambient, power
            }
            out.append(TempSensor(key: k, value: d, kind: kind))
        }
        return out.sorted { $0.value > $1.value }
    }

    /// Hottest curated surface sensor — the warmest spot your hands actually touch.
    func skinTemperature() -> Double? {
        Self.skinTempKeys.compactMap { value($0) }.filter { $0 > 0 && $0 < 80 }.max()
    }

    /// Temperature for a control "location" spec used by temp-hold mode:
    ///   "cpu" -> hottest CPU cluster sensor (default, legacy)
    ///   "skin" -> hottest chassis/surface sensor (heat near your hands)
    ///   "<KEY>" -> that exact SMC sensor key
    func controlTemperature(_ spec: String) -> Double? {
        switch spec.lowercased() {
        case "", "cpu": return cpuTemperature()
        case "skin", "hands": return skinTemperature()
        default:
            return value(spec)   // treat as an explicit sensor key
        }
    }
}
