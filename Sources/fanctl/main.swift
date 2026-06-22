// fanctl — amber-temp command-line fan control.
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
import AmberTempSMC

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
    if let t = smc.cpuTemperature() { print(String(format: "CPU: %.1f°C  (cluster average)", t)) }
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

let CONFIG_PATH = "/usr/local/etc/amber-temp/mode"

func ensureManual(_ smc: SMC) {
    let md = smc.fans().first?.mode ?? 0
    if md != 1 { _ = smc.engageManual() }   // re-engages after wake (Ftst reset to 0)
}

func applyTempControl(_ smc: SMC, setpoint: Double, margin: Double, ema: inout Double?) {
    guard let raw = smc.cpuTemperature() else { _ = smc.applyMax(); return }  // fail-safe: cool hard
    ema = ema == nil ? raw : (ema! * 0.7 + raw * 0.3)
    let temp = ema!
    if temp >= EMERGENCY_C { _ = smc.applyMax(); return }
    let tLow = setpoint - margin, tHigh = setpoint + margin
    for f in smc.fans() {
        let frac = temp <= tLow ? 0 : (temp >= tHigh ? 1 : (temp - tLow) / (tHigh - tLow))
        _ = smc.setTarget(f.index, rpm: f.min + (f.max - f.min) * frac)
    }
}

/// Apply a config line like "max", "scale 7", "rpm 4000", "temp 65 8", or "auto".
func applyModeString(_ line: String, _ smc: SMC, ema: inout Double?) {
    let parts = line.split(separator: " ").map(String.init)
    switch parts.first?.lowercased() ?? "max" {
    case "auto":  _ = smc.restoreAuto()
    case "scale": ensureManual(smc); if parts.count > 1, let v = Double(parts[1]) { _ = smc.applyScale(v) }
    case "rpm":   ensureManual(smc); if parts.count > 1, let v = Double(parts[1]) { _ = smc.applyRPM(v) }
    case "temp":
        ensureManual(smc)
        if parts.count > 1, let sp = Double(parts[1]) {
            let margin = parts.count > 2 ? (Double(parts[2]) ?? DEFAULT_MARGIN) : DEFAULT_MARGIN
            applyTempControl(smc, setpoint: sp, margin: margin, ema: &ema)
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
        fail("usage: fanctl temp <targetC> [margin]")
    }
    let margin = args.count > 2 ? (Double(args[2]) ?? DEFAULT_MARGIN) : DEFAULT_MARGIN
    let tLow = setpoint - margin, tHigh = setpoint + margin
    installSafetyHandlers()
    guard smc.engageManual() else { fail("Failed to engage manual control.") }
    print(String(format: "Holding CPU ≈ %.0f°C (ramp %.0f→%.0f). Ctrl-C to restore auto.", setpoint, tLow, tHigh))
    var ema: Double? = nil
    while true {
        guard let raw = smc.cpuTemperature() else {
            _ = smc.restoreAuto(); fail("Lost temperature reading — reverted to auto for safety.")
        }
        ema = ema == nil ? raw : (ema! * 0.7 + raw * 0.3)   // smooth the control input
        let temp = ema!
        if temp >= EMERGENCY_C {
            _ = smc.applyMax()
        } else {
            for f in smc.fans() {
                let frac: Double
                if temp <= tLow { frac = 0 }
                else if temp >= tHigh { frac = 1 }
                else { frac = (temp - tLow) / (tHigh - tLow) }
                _ = smc.setTarget(f.index, rpm: f.min + (f.max - f.min) * frac)
            }
        }
        let tgt = smc.fans().first?.target ?? 0
        print(String(format: "  %.1f°C -> %.0f rpm", temp, tgt))
        Thread.sleep(forTimeInterval: TEMP_INTERVAL)
    }

case "auto":
    requireRoot()
    if smc.restoreAuto() { print("Restored macOS automatic fan control."); printStatus() } else { fail("Write failed.") }

case "daemon":
    requireRoot()
    let path = args.count > 1 ? args[1] : CONFIG_PATH
    installSafetyHandlers()   // restore auto on SIGTERM/SIGINT
    var ema: Double? = nil
    FileHandle.standardError.write(Data("amber-temp daemon started (config: \(path))\n".utf8))
    while true {
        let line = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "max"
        applyModeString(line.isEmpty ? "max" : line, smc, ema: &ema)
        Thread.sleep(forTimeInterval: TEMP_INTERVAL)
    }

default:
    fail("""
    fanctl — amber-temp fan control
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
