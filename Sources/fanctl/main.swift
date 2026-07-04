// fanctl — amber-cool command-line fan control.
// Reads work unprivileged; writes (scale/rpm/max/temp/auto) require root.
//
//   fanctl                 read status (fans + CPU temp)
//   fanctl read            same
//   fanctl watch [secs]    live status loop (no root)
//   fanctl scale <0-10>    mode 1: coarse scale between min and max
//   fanctl rpm <value>     mode 2: explicit RPM (clamped per fan)
//   fanctl max             full blast
//   fanctl temp <C> [margin]   mode 3: hold a target CPU temp (control loop)
//   fanctl auto            hand control back to macOS

import Foundation
import AmberCoolSMC

let EMERGENCY_C = 95.0   // force max above this regardless of setpoint
let DEFAULT_MARGIN = 7.5 // ramp half-width for temp mode
let TEMP_INTERVAL = 2.0  // seconds between recompute (TG Pro default)

func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }
func isRoot() -> Bool { geteuid() == 0 }
func requireRoot() { if !isRoot() { fail("This command writes the SMC and needs root. Re-run with: sudo \(CommandLine.arguments.joined(separator: " "))") } }

let smc = SMC()
guard smc.open() else { fail("Could not open AppleSMC service.") }

func printStatus() {
    let fans = smc.fans()
    if fans.isEmpty { print("No fans found (FNum=0)."); return }
    let modeName = ["0":"auto","1":"manual","3":"system"]
    for f in fans {
        let md = modeName[String(f.mode)] ?? "mode \(f.mode)"
        print(String(format: "Fan %d: %4.0f rpm  (target %4.0f, range %.0f–%.0f, %@)",
                     f.index, f.actual, f.target, f.min, f.max, md))
    }
    if let t = smc.skinTemperature() { print(String(format: "Hands: %.1f°C  (hottest palm/wrist/skin sensor)", t)) }
    if let t = smc.cpuTemperature() { print(String(format: "CPU:   %.1f°C  (hottest die sensor)", t)) }
    print("Ftst unlock: \(smc.hasFtst ? "present" : "absent")")
}

// Restore auto on interrupt/terminate so we never leave the machine pinned.
func installSafetyHandlers() {
    let restore: @convention(c) (Int32) -> Void = { _ in
        let s = SMC(); if s.open() { _ = s.restoreAuto(); s.close() }
        FileHandle.standardError.write(Data("\nfanctl: restored macOS auto fan control.\n".utf8))
        exit(0)
    }
    signal(SIGINT, restore)
    signal(SIGTERM, restore)
}

let CONFIG_PATH = "/usr/local/etc/amber-cool/mode"

func ensureManual(_ smc: SMC) {
    let md = smc.fans().first?.mode ?? 0
    if md != 1 { _ = smc.engageManual() }   // re-engages after wake (Ftst reset to 0)
}

/// Margin (ramp half-width) appropriate to a control location: surfaces move in a narrow band,
/// the die swings wide.
func defaultMargin(_ location: String) -> Double { location.lowercased() == "cpu" ? DEFAULT_MARGIN : 3.0 }

/// Hold a target temperature at a chosen LOCATION ("skin"/"hands", "cpu", or an explicit sensor key).
/// CPU-die emergency protection ALWAYS runs first — even when controlling toward hand temp, a burst
/// must never cook the silicon while your palms stay cool.
func applyTempControl(_ smc: SMC, setpoint: Double, location: String, margin: Double, ema: inout Double?) {
    if let die = smc.cpuTemperature(), die >= EMERGENCY_C { _ = smc.applyMax(); return }
    guard let raw = smc.controlTemperature(location) else { _ = smc.applyMax(); return }  // fail-safe: cool hard
    ema = ema == nil ? raw : (ema! * 0.7 + raw * 0.3)
    let temp = ema!
    let tLow = setpoint - margin, tHigh = setpoint + margin
    for f in smc.fans() {
        let frac = temp <= tLow ? 0 : (temp >= tHigh ? 1 : (temp - tLow) / (tHigh - tLow))
        _ = smc.setTarget(f.index, rpm: f.min + (f.max - f.min) * frac)
    }
}

/// Apply a config line like "max", "scale 7", "rpm 4000", "temp 35 skin", "temp 65 cpu 8", or "auto".
/// temp format: `temp <targetC> [location] [margin]`  (location defaults to "skin" — heat to your hands).
func applyModeString(_ line: String, _ smc: SMC, ema: inout Double?) {
    let parts = line.split(separator: " ").map(String.init)
    switch parts.first?.lowercased() ?? "max" {
    case "auto":  _ = smc.restoreAuto()
    case "scale": ensureManual(smc); if parts.count > 1, let v = Double(parts[1]) { _ = smc.applyScale(v) }
    case "rpm":   ensureManual(smc); if parts.count > 1, let v = Double(parts[1]) { _ = smc.applyRPM(v) }
    case "temp":
        ensureManual(smc)
        if parts.count > 1, let sp = Double(parts[1]) {
            let location = parts.count > 2 ? parts[2] : "skin"
            let margin = parts.count > 3 ? (Double(parts[3]) ?? defaultMargin(location)) : defaultMargin(location)
            applyTempControl(smc, setpoint: sp, location: location, margin: margin, ema: &ema)
        }
    default: ensureManual(smc); _ = smc.applyMax()
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "read"

switch cmd {

case "read":
    printStatus()

case "watch":
    let secs = args.count > 1 ? (Double(args[1]) ?? 1.0) : 1.0
    while true {
        print("\u{001B}[2J\u{001B}[H", terminator: "")  // clear
        printStatus()
        Thread.sleep(forTimeInterval: secs)
    }

case "scale":
    requireRoot()
    guard args.count > 1, let s = Double(args[1]), s >= 0, s <= 10 else { fail("usage: fanctl scale <0-10>") }
    guard smc.engageManual() else { fail("Failed to engage manual control (Ftst handshake).") }
    if smc.applyScale(s) { print("Set scale \(s)/10."); printStatus() } else { fail("Write failed.") }

case "rpm":
    requireRoot()
    guard args.count > 1, let r = Double(args[1]), r >= 0 else { fail("usage: fanctl rpm <value>") }
    guard smc.engageManual() else { fail("Failed to engage manual control.") }
    if smc.applyRPM(r) { print("Set target \(Int(r)) rpm (clamped per fan)."); printStatus() } else { fail("Write failed.") }

case "max":
    requireRoot()
    guard smc.engageManual() else { fail("Failed to engage manual control.") }
    if smc.applyMax() { print("FULL BLAST engaged."); printStatus() } else { fail("Write failed.") }

case "temp":
    requireRoot()
    guard args.count > 1, let setpoint = Double(args[1]), setpoint > 0, setpoint < 110 else {
        fail("usage: fanctl temp <targetC> [location] [margin]   (location: skin|hands|cpu|<KEY>, default skin)")
    }
    let location = args.count > 2 ? args[2] : "skin"
    let margin = args.count > 3 ? (Double(args[3]) ?? defaultMargin(location)) : defaultMargin(location)
    installSafetyHandlers()
    guard smc.engageManual() else { fail("Failed to engage manual control.") }
    print(String(format: "Holding %@ ~ %.0f C (ramp %.0f-%.0f). Ctrl-C to restore auto.",
                 location, setpoint, setpoint - margin, setpoint + margin))
    var ema: Double? = nil
    while true {
        guard smc.controlTemperature(location) != nil else {
            _ = smc.restoreAuto(); fail("Lost '\(location)' temperature reading - reverted to auto for safety.")
        }
        applyTempControl(smc, setpoint: setpoint, location: location, margin: margin, ema: &ema)
        let tgt = smc.fans().first?.target ?? 0
        print(String(format: "  %@ %.1f C -> %.0f rpm", location, ema ?? 0, tgt))
        Thread.sleep(forTimeInterval: TEMP_INTERVAL)
    }

case "temps":   // diagnostic: dump each CPU sensor key, raw bytes, decoded value
    for k in SMC.cpuTempKeys {
        if let v = smc.read(k) {
            let dec = SMC.decode(v).map { String(format: "%.1f", $0) } ?? "—"
            print("\(k)  type=\(v.type)  raw=\(Array(v.bytes.prefix(v.size)))  decoded=\(dec)")
        } else {
            print("\(k)  (unreadable)")
        }
    }
    if let t = smc.cpuTemperature() { print(String(format: "average = %.1f°C", t)) }

case "sensors":   // enumerate EVERY temperature sensor (no root), classified die/skin/other
    let sensors = smc.allTemperatureSensors()
    if sensors.isEmpty { print("No temperature sensors found."); break }
    print("ALL TEMPERATURE SENSORS  (\(sensors.count) found, hottest first)")
    print("  skin = chassis/surface near your hands (~20–48°C) · die = CPU/GPU silicon · other = battery/ambient/power\n")
    for kind in ["skin", "die", "other"] {
        let group = sensors.filter { $0.kind.rawValue == kind }
        guard !group.isEmpty else { continue }
        print("[\(kind.uppercased())]")
        for s in group { print(String(format: "  %@  %.1f°C", s.key, s.value)) }
        print("")
    }
    if let c = smc.cpuTemperature() { print(String(format: "control: cpu=%.1f°C", c)) }
    if let s = smc.controlTemperature("skin") { print(String(format: "control: skin=%.1f°C", s)) }

case "auto":
    requireRoot()
    if smc.restoreAuto() { print("Restored macOS automatic fan control."); printStatus() } else { fail("Write failed.") }

case "daemon":
    requireRoot()
    let path = args.count > 1 ? args[1] : CONFIG_PATH
    installSafetyHandlers()   // restore auto on SIGTERM/SIGINT
    var ema: Double? = nil
    FileHandle.standardError.write(Data("amber-cool daemon started (config: \(path))\n".utf8))
    let iso = ISO8601DateFormatter()
    while true {
        let line = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "max"
        let mode = line.isEmpty ? "max" : line
        applyModeString(mode, smc, ema: &ema)
        let hands = smc.skinTemperature().map { String(format: "%.1f", $0) } ?? "—"
        let cpu = smc.cpuTemperature().map { String(format: "%.1f", $0) } ?? "—"
        let targets = smc.fans().map { Int($0.target) }
        let actual = smc.fans().map { Int($0.actual) }
        print("\(iso.string(from: Date())) [daemon] mode='\(mode)' hands=\(hands) cpu=\(cpu) targets=\(targets) actual=\(actual)")
        fflush(stdout)
        Thread.sleep(forTimeInterval: TEMP_INTERVAL)
    }

default:
    fail("""
    fanctl — amber-cool fan control
      fanctl [read]          status
      fanctl watch [secs]    live loop
      fanctl scale <0-10>    coarse scale          (root)
      fanctl rpm <value>     explicit RPM          (root)
      fanctl max             full blast            (root)
      fanctl temp <C> [m]    hold target temp      (root)
      fanctl auto            back to macOS auto     (root)
      fanctl daemon [path]   run as a service, reading mode from a config file (root)
    """)
}

smc.close()
