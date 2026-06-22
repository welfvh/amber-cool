// amber-temp — menu bar app. A native dropdown menu (MenuBarExtra .menu style) showing
// live fan/temp status and switching between the three modes. Menu items deliver clicks
// reliably (the .window popover style did not). Fan writes are done by the root daemon
// (`fanctl daemon`); the app reads the SMC directly (no root) and writes the mode to the
// daemon's config file to change behavior.

import SwiftUI
import AppKit
import AmberTempSMC

let MODE_CONFIG_PATH = "/usr/local/etc/amber-temp/mode"
let APP_LOG_PATH = NSString(string: "~/Library/Logs/amber-temp-app.log").expandingTildeInPath

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

    init() {
        let opened = smc.open()
        appLog("app start: smc.open()=\(opened) fanCount=\(smc.fanCount)")
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
        daemonInstalled = FileManager.default.fileExists(atPath: MODE_CONFIG_PATH)
        currentMode = (try? String(contentsOfFile: MODE_CONFIG_PATH, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
        appLog("refresh fans_actual=\(fans.map { Int($0.actual) }) fans_target=\(fans.map { Int($0.target) }) hands=\(String(format: "%.1f", skinTemp))(raw \(String(format: "%.1f", rawSkin))) cpu=\(String(format: "%.1f", cpuTemp))(raw \(String(format: "%.1f", rawCpu))) mode='\(currentMode)'")
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
        return cpuTemp > 0 ? String(format: "%.0f° %.1fk", cpuTemp, rpm / 1000) : "amber-temp"
    }

    /// Write a mode line the daemon will pick up. IMPORTANT: write in place (atomically:false) —
    /// the config dir is root-owned, so an atomic write (temp file + rename in that dir) fails
    /// silently; the file itself is user-writable (0666).
    func setMode(_ line: String) {
        var writeOK = false
        var writeErr = "—"
        do {
            try (line + "\n").write(toFile: MODE_CONFIG_PATH, atomically: false, encoding: .utf8)
            writeOK = true
        } catch {
            writeErr = "\(error)"
        }
        let readback = (try? String(contentsOfFile: MODE_CONFIG_PATH, encoding: .utf8))?
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

        if !model.daemonInstalled {
            Text("⚠︎ daemon not installed — changes won't apply")
        }
        Button("Refresh") { model.refresh() }
        Button("Quit amber-temp") { NSApplication.shared.terminate(nil) }
    }
}

@main
struct AmberTempApp: App {
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
