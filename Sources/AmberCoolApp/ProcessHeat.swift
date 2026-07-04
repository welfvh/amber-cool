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
        "cfprefsd", "coreaudiod", "amber-cool"
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

    // Generic interpreters whose own name ("Python", "node") tells you nothing about WHAT is running.
    // For these we dig out the actual script + project so the kill label is meaningful (and safe).
    private static let interpreters: Set<String> = [
        "python", "python3", "node", "ruby", "perl", "java", "bash", "zsh", "sh", "deno", "bun", "Rscript"
    ]

    /// argv for a pid via KERN_PROCARGS2 (works for your own processes, no root).
    static func processArgs(_ pid: Int32) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var idx = 4
        while idx < size, buf[idx] != 0 { idx += 1 }      // skip exec path
        while idx < size, buf[idx] == 0 { idx += 1 }       // skip padding nulls
        var args: [String] = [], cur: [UInt8] = [], got = 0
        while idx < size, got < Int(argc) {
            if buf[idx] == 0 { args.append(String(decoding: cur, as: UTF8.self)); cur.removeAll(); got += 1 }
            else { cur.append(buf[idx]) }
            idx += 1
        }
        return args
    }

    /// Current working directory of a pid (for project context). PROC_PIDVNODEPATHINFO = 9.
    static func cwdName(_ pid: Int32) -> String? {
        var vpi = proc_vnodepathinfo()
        let r = proc_pidinfo(pid, 9, 0, &vpi, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard r > 0 else { return nil }
        let path = withUnsafeBytes(of: vpi.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? nil : last
    }

    /// Human display name. .app → bundle name. Interpreter → "script · project" so you can tell
    /// what you'd actually be killing (e.g. "build.py · pipeline", not just "Python").
    static func displayName(_ pid: Int32, fallback: String) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return fallback }
        let path = String(cString: buf)
        let exe = (path as NSString).lastPathComponent

        // Interpreter check FIRST — framework pythons live in a Python.app bundle, so the .app
        // rule below would otherwise mislabel them "Python" and hide the real script.
        guard interpreters.contains(exe.lowercased()) else {
            if let r = path.range(of: ".app/") {
                let appName = (String(path[..<r.lowerBound]) + ".app" as NSString).lastPathComponent
                return appName.replacingOccurrences(of: ".app", with: "")
            }
            return exe
        }

        // It's an interpreter — find the script/module from argv.
        let args = processArgs(pid)
        var label: String? = nil
        var i = 1
        while i < args.count {
            let a = args[i]
            if a == "-m", i + 1 < args.count { label = args[i + 1]; break }   // python -m http.server
            if a.hasPrefix("-") { i += 1; continue }                          // skip flags
            label = (a as NSString).lastPathComponent                         // the script
            break
        }
        guard let script = label, !script.isEmpty else { return exe }
        if let proj = cwdName(pid), proj != script { return "\(script) · \(proj)" }
        return script
    }

    /// Graceful kill. SIGTERM only — the app gets to clean up / prompt to save.
    @discardableResult
    static func terminate(_ pid: Int32) -> Bool { kill(pid, SIGTERM) == 0 }
}
