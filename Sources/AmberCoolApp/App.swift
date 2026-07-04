// amber-cool — menu bar app. A native dropdown menu (MenuBarExtra .menu style) showing
// live fan/temp status and switching between the three modes. Menu items deliver clicks
// reliably (the .window popover style did not). Fan writes are done by the root daemon
// (`fanctl daemon`); the app reads the SMC directly (no root) and writes the mode to the
// daemon's config file to change behavior.

import SwiftUI
import AppKit
import ServiceManagement
import AmberCoolSMC

// Prefer the amber-cool config; fall back to the pre-rename amber-temp path so the app
// keeps controlling a daemon that hasn't been reinstalled under the new name yet.
// Resolved per access, not once at launch — the daemon can be reinstalled under the
// new name while the app is running, and the app must follow it to the new path.
func modeConfigPath() -> String {
    let new = "/usr/local/etc/amber-cool/mode"
    let old = "/usr/local/etc/amber-temp/mode"
    return FileManager.default.fileExists(atPath: new) ? new : old
}
let APP_LOG_PATH = NSString(string: "~/Library/Logs/amber-cool-app.log").expandingTildeInPath

func appLog(_ s: String) {
    let line = ISO8601DateFormatter().string(from: Date()) + " " + s + "\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: APP_LOG_PATH) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: APP_LOG_PATH))
    }
}

@MainActor
final class FanModel: ObservableObject {
    private let smc = SMC()
    private var timer: Timer?

    @Published var fans: [FanInfo] = []
    @Published var cpuTemp: Double = 0
    @Published var skinTemp: Double = 0        // hottest palm/wrist/skin sensor — what your hands feel
    @Published var currentMode: String = "—"
    @Published var daemonInstalled = false
    @Published var topProcs: [HeatProc] = []      // user-owned CPU hogs (heat sources)
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var prevCpu: [Int32: UInt64] = [:]    // pid -> cumulative cpu ns, last sample
    private var prevCpuWall: Double = 0           // monotonic ns of last sample

    init() {
        let opened = smc.open()
        appLog("app start: smc.open()=\(opened) fanCount=\(smc.fanCount)")
        // Auto-enroll as a login item on first run — a menu bar app that isn't running
        // is invisible, which defeats the point. The menu has a toggle to opt out.
        if SMAppService.mainApp.status == .notRegistered {
            do { try SMAppService.mainApp.register() } catch { appLog("login item register failed: \(error)") }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        refresh()
        // Default-mode timer ON PURPOSE: it is SUSPENDED while the menu is open (event tracking),
        // so the open NSMenu stays static and clickable. Refreshing @Published during tracking
        // rebuilds the menu every tick → flicker + swallowed clicks. The live numbers you watch
        // are in the menu-bar TITLE (visible when the menu is closed); the menu shows a snapshot
        // that's at most 1s stale and re-reads each time you open it.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        fans = smc.fans()
        // Hottest die / surface sensors are a MAX across many per-core sensors, so the raw value
        // wobbles as individual cores spike. EMA-smooth the DISPLAY so the number is stable
        // (the control loop smooths separately). alpha 0.4 ≈ ~90% response in ~5s.
        let rawCpu = smc.cpuTemperature() ?? 0
        let rawSkin = smc.skinTemperature() ?? 0
        cpuTemp = cpuTemp <= 0 ? rawCpu : cpuTemp * 0.6 + rawCpu * 0.4
        skinTemp = skinTemp <= 0 ? rawSkin : skinTemp * 0.6 + rawSkin * 0.4
        daemonInstalled = FileManager.default.fileExists(atPath: modeConfigPath())
        currentMode = (try? String(contentsOfFile: modeConfigPath(), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
        updateTopProcs()
        appLog("refresh fans_actual=\(fans.map { Int($0.actual) }) fans_target=\(fans.map { Int($0.target) }) hands=\(String(format: "%.1f", skinTemp))(raw \(String(format: "%.1f", rawSkin))) cpu=\(String(format: "%.1f", cpuTemp))(raw \(String(format: "%.1f", rawCpu))) mode='\(currentMode)' top=\(topProcs.prefix(3).map { "\($0.name):\(Int($0.cpu))%" })")
    }

    /// Sample CPU deltas over the refresh interval and publish the top user-owned consumers.
    /// Runs only on the refresh timer (suspended during menu tracking) so the menu never rebuilds
    /// mid-open. Cost: one proc_pidinfo per pid (~a few ms), plus a few lookups for the top candidates.
    private func updateTopProcs() {
        let now = ProcessHeat.monotonicNs()
        let pids = ProcessHeat.allPids()
        var cur: [Int32: UInt64] = [:]
        cur.reserveCapacity(pids.count)
        for p in pids { if let c = ProcessHeat.cpuNs(p) { cur[p] = c } }

        if prevCpuWall > 0, now > prevCpuWall {
            let wall = now - prevCpuWall
            let me = getpid(), myUid = getuid()
            // Rank by CPU delta first (cheap), then resolve uid/name only for the top candidates.
            let ranked = cur.compactMap { (pid, c1) -> (Int32, Double)? in
                guard pid != me, let c0 = prevCpu[pid], c1 >= c0 else { return nil }
                let cpu = Double(c1 &- c0) / wall * 100.0
                return cpu >= 0.5 ? (pid, cpu) : nil
            }.sorted { $0.1 > $1.1 }

            var result: [HeatProc] = []
            for (pid, cpu) in ranked {
                if result.count >= 8 { break }
                guard let bi = ProcessHeat.bsdInfo(pid), bi.uid == myUid else { continue } // my apps + helpers
                let name = ProcessHeat.displayName(pid, fallback: bi.comm)
                if ProcessHeat.denylist.contains(name) || ProcessHeat.denylist.contains(bi.comm) { continue }
                result.append(HeatProc(pid: pid, name: name, cpu: cpu))
            }
            topProcs = result
        }
        prevCpu = cur
        prevCpuWall = now
    }

    func killProc(_ p: HeatProc) {
        let ok = ProcessHeat.terminate(p.pid)
        appLog("killProc('\(p.name)' pid=\(p.pid) cpu=\(Int(p.cpu))%) SIGTERM ok=\(ok)")
        refresh()
    }

    /// Title shows IS/OUGHT: current temp at the controlled location / target. In a non-temp mode
    /// (scale/rpm/max/auto) there's no target, so it shows current hands temp + max fan rpm.
    var menuTitle: String {
        let parts = currentMode.split(separator: " ").map(String.init)
        if parts.first == "temp", parts.count >= 2, let target = Double(parts[1]) {
            let cpuLoc = parts.count >= 3 && parts[2].lowercased() == "cpu"
            let current = cpuLoc ? cpuTemp : skinTemp
            return current > 0 ? String(format: "%.0f/%.0f°", current, target)
                               : String(format: "–/%.0f°", target)
        }
        let rpm = fans.map(\.actual).max() ?? 0
        if skinTemp > 0 { return String(format: "%.0f° %.1fk", skinTemp, rpm / 1000) }
        return cpuTemp > 0 ? String(format: "%.0f° %.1fk", cpuTemp, rpm / 1000) : "Amber Cool"
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            appLog("login item \(on ? "register" : "unregister") failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Write a mode line the daemon will pick up. IMPORTANT: write in place (atomically:false) —
    /// the config dir is root-owned, so an atomic write (temp file + rename in that dir) fails
    /// silently; the file itself is user-writable (0666).
    func setMode(_ line: String) {
        var writeOK = false
        var writeErr = "—"
        do {
            try (line + "\n").write(toFile: modeConfigPath(), atomically: false, encoding: .utf8)
            writeOK = true
        } catch {
            writeErr = "\(error)"
        }
        let readback = (try? String(contentsOfFile: modeConfigPath(), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        appLog("setMode('\(line)') writeOK=\(writeOK) err=\(writeErr) readback='\(readback)'")
        currentMode = line
        refresh()
    }
}

struct MenuContent: View {
    @ObservedObject var model: FanModel
    private let rpmPresets = [2000, 2500, 3000, 3500, 4000, 4500, 5000, 6000, 7000]
    private let handsPresets = [33, 35, 37, 39, 41]   // surface °C — what your palms feel
    private let cpuPresets = [55, 65, 75, 85]         // die °C

    var body: some View {
        // Live status (Text in a .menu renders as disabled label rows)
        ForEach(model.fans, id: \.index) { f in
            Text(verbatim: "Fan \(f.index):  \(Int(f.actual)) rpm")   // verbatim: no locale separators
        }
        Text(verbatim: model.skinTemp > 0 ? "Hands: \(Int(model.skinTemp))°C  (palms/wrist)" : "Hands: —")
        Text(verbatim: model.cpuTemp > 0 ? "CPU:   \(Int(model.cpuTemp))°C  (die)" : "CPU:   —")
        Text(verbatim: "Mode:  \(model.currentMode)")

        Divider()

        Button("System (Auto)") { model.setMode("auto") }
        Button("Full blast") { model.setMode("max") }

        Menu("Scale 0–10") {
            ForEach(0...10, id: \.self) { n in
                let suffix = n == 0 ? "  (quiet)" : (n == 10 ? "  (max)" : "")
                Button("\(n)\(suffix)") { model.setMode("scale \(n)") }
            }
        }
        Menu("Custom RPM") {
            ForEach(rpmPresets, id: \.self) { r in
                Button("\(r) rpm") { model.setMode("rpm \(r)") }
            }
        }
        Menu("Hold temperature") {
            Section("Hands (palms / wrist)") {
                ForEach(handsPresets, id: \.self) { t in
                    Button("≤ \(t) °C") { model.setMode("temp \(t) skin") }
                }
            }
            Section("CPU die") {
                ForEach(cpuPresets, id: \.self) { t in
                    Button("≤ \(t) °C") { model.setMode("temp \(t) cpu") }
                }
            }
        }

        Divider()

        Menu("Top heat sources") {
            if model.topProcs.isEmpty {
                Text("(nothing notable right now)")
            } else {
                Section("Click to quit (graceful)") {
                    ForEach(model.topProcs) { p in
                        Button("Kill \(p.name) — \(Int(p.cpu))%") { model.killProc(p) }
                    }
                }
            }
        }

        Divider()

        if !model.daemonInstalled {
            Text("⚠︎ daemon not installed — changes won't apply")
        }
        Toggle("Launch at login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))
        Button("Refresh") { model.refresh() }
        Button("Quit Amber Cool") { NSApplication.shared.terminate(nil) }
    }
}

@main
struct AmberCoolApp: App {
    @StateObject private var model = FanModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Text(model.menuTitle)
        }
        .menuBarExtraStyle(.menu)
    }
}
