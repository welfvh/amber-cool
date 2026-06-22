// ProcessHeat — find the processes burning the most CPU (= making the most heat)
// and offer a 1-click graceful kill. Native libproc only (no shelling).
//
// Scope (per Welf): "my apps + helpers" — only processes owned by the current user
// (your uid, which includes your own background agents), never root/system daemons,
// and never a hard denylist of session-critical UI processes. Kill = SIGTERM (graceful:
// the app gets to save / prompt), never SIGKILL.

import Foundation
import Darwin

struct HeatProc: Identifiable {
    let pid: Int32
    let name: String
    let cpu: Double      // percent of ONE core (matches Activity Monitor; >100% = multi-core)
    var id: Int32 { pid }
}

enum ProcessHeat {
    // proc_info flavors / pid-list type (defined locally so we don't depend on macro imports)
    private static let ALL_PIDS: UInt32 = 1
    private static let PIDTASKINFO: Int32 = 4
    private static let PIDTBSDINFO: Int32 = 3

    /// Session-critical processes we never offer to kill even if user-owned (most relaunch, but
    /// killing them is disruptive). Matched against both the .app display name and the BSD comm.
    static let denylist: Set<String> = [
        "WindowServer", "loginwindow", "Dock", "SystemUIServer", "ControlCenter",
        "NotificationCenter", "Spotlight", "Finder", "WindowManager", "launchd",
        "cfprefsd", "coreaudiod", "amber-temp"
    ]

    /// Nanoseconds per mach absolute-time tick. On Apple Silicon this is ~41.67 (numer 125 / denom 3);
    /// on Intel it's 1.0. proc_taskinfo CPU times are in mach ticks, so we must convert to ns.
    static let nsPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    static func monotonicNs() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) * 1e9 + Double(ts.tv_nsec)
    }

    static func allPids() -> [Int32] {
        let n = proc_listpids(ALL_PIDS, 0, nil, 0)
        guard n > 0 else { return [] }
        let cap = Int(n) / MemoryLayout<Int32>.stride + 32
        var pids = [Int32](repeating: 0, count: cap)
        let n2 = proc_listpids(ALL_PIDS, 0, &pids, Int32(cap * MemoryLayout<Int32>.stride))
        guard n2 > 0 else { return [] }
        let c = Int(n2) / MemoryLayout<Int32>.stride
        return Array(pids.prefix(c)).filter { $0 > 0 }
    }

    /// Cumulative CPU time (user+system) in nanoseconds for a pid.
    static func cpuNs(_ pid: Int32) -> UInt64? {
        var ti = proc_taskinfo()
        let sz = Int32(MemoryLayout<proc_taskinfo>.size)
        let r = proc_pidinfo(pid, PIDTASKINFO, 0, &ti, sz)
        guard r == sz else { return nil }
        let ticks = ti.pti_total_user &+ ti.pti_total_system   // mach absolute-time units
        return UInt64(Double(ticks) * nsPerTick)               // -> nanoseconds
    }

    /// (uid, comm) for a pid, or nil if unreadable.
    static func bsdInfo(_ pid: Int32) -> (uid: uid_t, comm: String)? {
        var bi = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        let r = proc_pidinfo(pid, PIDTBSDINFO, 0, &bi, sz)
        guard r == sz else { return nil }
        let comm = withUnsafeBytes(of: bi.pbi_comm) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return (bi.pbi_uid, comm)
    }

    /// Human display name: prefer the .app bundle name from the executable path, else comm.
    static func displayName(_ pid: Int32, fallback: String) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return fallback }
        let path = String(cString: buf)
        if let r = path.range(of: ".app/") {
            let appName = (String(path[..<r.lowerBound]) + ".app" as NSString).lastPathComponent
            return appName.replacingOccurrences(of: ".app", with: "")
        }
        return (path as NSString).lastPathComponent
    }

    /// Graceful kill. SIGTERM only — the app gets to clean up / prompt to save.
    @discardableResult
    static func terminate(_ pid: Int32) -> Bool { kill(pid, SIGTERM) == 0 }
}
