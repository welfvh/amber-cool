// amber-temp — menu bar app. SwiftUI MenuBarExtra showing live fan/temp status
// and switching between the three modes. Fan writes are done by the root daemon
// (`fanctl daemon`); the app reads the SMC directly (no root) for status and
// writes the mode to the daemon's config file to change behavior.

import SwiftUI
import AppKit
import AmberTempSMC

let MODE_CONFIG_PATH = "/usr/local/etc/amber-temp/mode"

@MainActor
final class FanModel: ObservableObject {
    private let smc = SMC()
    private var timer: Timer?

    @Published var fans: [FanInfo] = []
    @Published var cpuTemp: Double = 0
    @Published var currentMode: String = "—"
    @Published var daemonInstalled = false

    init() {
        _ = smc.open()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        fans = smc.fans()
        cpuTemp = smc.cpuTemperature() ?? 0
        daemonInstalled = FileManager.default.fileExists(atPath: MODE_CONFIG_PATH)
        currentMode = (try? String(contentsOfFile: MODE_CONFIG_PATH, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
    }

    var menuTitle: String {
        let rpm = fans.map(\.actual).max() ?? 0
        if cpuTemp <= 0 { return "—" }
        return String(format: "%.0f° %.1fk", cpuTemp, rpm / 1000)
    }

    /// Write a mode line the daemon will pick up (e.g. "max", "scale 7", "rpm 4000", "temp 65").
    func setMode(_ line: String) {
        try? line.write(toFile: MODE_CONFIG_PATH, atomically: true, encoding: .utf8)
        currentMode = line
        refresh()
    }
}

struct ContentView: View {
    @ObservedObject var model: FanModel
    @State private var scale: Double = 5
    @State private var rpm: String = "4000"
    @State private var tempTarget: String = "65"

    private func isActive(_ prefix: String) -> Bool { model.currentMode.hasPrefix(prefix) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("amber-temp").font(.headline).foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.30))

            // Live status
            ForEach(model.fans, id: \.index) { f in
                Text(String(format: "Fan %d   %4.0f rpm   (→ %4.0f)", f.index, f.actual, f.target))
                    .font(.system(.caption, design: .monospaced))
            }
            Text(model.cpuTemp > 0 ? String(format: "CPU   %.1f °C", model.cpuTemp) : "CPU   —")
                .font(.system(.caption, design: .monospaced))
            Text("mode: \(model.currentMode)").font(.caption2).foregroundStyle(.secondary)

            Divider()

            HStack {
                Button("System (Auto)") { model.setMode("auto") }
                Button("Full blast") { model.setMode("max") }.tint(.orange)
            }

            // Mode 1 — scale 0–10
            HStack {
                Text("Scale").frame(width: 44, alignment: .leading)
                Slider(value: $scale, in: 0...10, step: 1)
                Text("\(Int(scale))").frame(width: 18)
                Button("Set") { model.setMode("scale \(Int(scale))") }
            }
            // Mode 2 — custom RPM
            HStack {
                Text("RPM").frame(width: 44, alignment: .leading)
                TextField("4000", text: $rpm).frame(width: 70)
                Button("Set") { model.setMode("rpm \(rpm)") }
            }
            // Mode 3 — temperature target
            HStack {
                Text("Hold °C").frame(width: 44, alignment: .leading)
                TextField("65", text: $tempTarget).frame(width: 70)
                Button("Set") { model.setMode("temp \(tempTarget)") }
            }

            if !model.daemonInstalled {
                Divider()
                Text("Daemon not installed — fan changes won't apply.\nRun: sudo ./daemon/install.sh")
                    .font(.caption2).foregroundStyle(.orange)
            }

            Divider()
            Button("Quit amber-temp") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280)
    }
}

@main
struct AmberTempApp: App {
    @StateObject private var model = FanModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            Text(model.menuTitle)
        }
        .menuBarExtraStyle(.window)
    }
}
