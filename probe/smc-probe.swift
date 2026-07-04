// amber-cool SMC probe — READ-ONLY. Confirms the SMC substrate on this Mac.
// Reads fan count, per-fan RPM/min/max/target/mode, Ftst presence, and a few temps.
// Does NOT write anything. No root required for reads.
//
// Builds the 80-byte AppleSMC param buffer at explicit C offsets (Swift struct layout
// is not guaranteed to match C, so we poke fields by offset instead).
//
// Build: swiftc -O probe/smc-probe.swift -o probe/smc-probe -framework IOKit
// Run:   ./probe/smc-probe

import Foundation
import IOKit

// SMCParamStruct C layout (total 80 bytes), field offsets we touch:
//   key        UInt32 @0
//   keyInfo.dataSize UInt32 @28
//   keyInfo.dataType UInt32 @32
//   result     UInt8  @40
//   data8 (selector) UInt8 @42
//   bytes[32]  @48
let STRUCT_SIZE = 80
let OFF_KEY = 0
let OFF_DATASIZE = 28
let OFF_DATATYPE = 32
let OFF_RESULT = 40
let OFF_DATA8 = 42
let OFF_BYTES = 48

let KERNEL_INDEX_SMC: UInt32 = 2
let SMC_CMD_READ_BYTES: UInt8 = 5
let SMC_CMD_READ_KEYINFO: UInt8 = 9

func fourCharCode(_ s: String) -> UInt32 {
    var r: UInt32 = 0
    for c in s.utf8 { r = (r << 8) | UInt32(c) }
    return r
}
func codeToString(_ v: UInt32) -> String {
    let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
             UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? "?"
}

func makeBuf() -> [UInt8] { [UInt8](repeating: 0, count: STRUCT_SIZE) }
func setU32(_ buf: inout [UInt8], _ off: Int, _ v: UInt32) {  // native little-endian (arm64)
    buf[off]   = UInt8(v & 0xff)
    buf[off+1] = UInt8((v >> 8) & 0xff)
    buf[off+2] = UInt8((v >> 16) & 0xff)
    buf[off+3] = UInt8((v >> 24) & 0xff)
}
func getU32(_ buf: [UInt8], _ off: Int) -> UInt32 {
    UInt32(buf[off]) | (UInt32(buf[off+1]) << 8) | (UInt32(buf[off+2]) << 16) | (UInt32(buf[off+3]) << 24)
}

var conn: io_connect_t = 0
let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
guard service != 0 else { print("AppleSMC service not found"); exit(1) }
let openResult = IOServiceOpen(service, mach_task_self_, 0, &conn)
IOObjectRelease(service)
guard openResult == kIOReturnSuccess else {
    print(String(format: "IOServiceOpen failed: 0x%08x", openResult)); exit(1)
}

func call(_ input: [UInt8]) -> (kern_return_t, [UInt8]) {
    var output = [UInt8](repeating: 0, count: STRUCT_SIZE)
    var outSize = STRUCT_SIZE
    let kr = input.withUnsafeBytes { inPtr in
        output.withUnsafeMutableBytes { outPtr in
            IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC,
                                      inPtr.baseAddress, STRUCT_SIZE,
                                      outPtr.baseAddress, &outSize)
        }
    }
    return (kr, output)
}

struct SMCReadResult { var dataType: String; var size: Int; var bytes: [UInt8] }

func readKey(_ key: String) -> SMCReadResult? {
    var inp = makeBuf()
    setU32(&inp, OFF_KEY, fourCharCode(key))
    inp[OFF_DATA8] = SMC_CMD_READ_KEYINFO
    let (kr1, info) = call(inp)
    guard kr1 == kIOReturnSuccess, info[OFF_RESULT] == 0 else { return nil }
    let dataSize = getU32(info, OFF_DATASIZE)
    let dataType = getU32(info, OFF_DATATYPE)
    guard dataSize > 0 else { return nil }

    var inp2 = makeBuf()
    setU32(&inp2, OFF_KEY, fourCharCode(key))
    setU32(&inp2, OFF_DATASIZE, dataSize)
    inp2[OFF_DATA8] = SMC_CMD_READ_BYTES
    let (kr2, out) = call(inp2)
    guard kr2 == kIOReturnSuccess, out[OFF_RESULT] == 0 else { return nil }

    let n = min(Int(dataSize), 32)
    let bytes = Array(out[OFF_BYTES..<(OFF_BYTES + n)])
    return SMCReadResult(dataType: codeToString(dataType), size: Int(dataSize), bytes: bytes)
}

func decode(_ r: SMCReadResult) -> Double? {
    switch r.dataType {
    case "flt ": guard r.bytes.count >= 4 else { return nil }
        return Double(r.bytes.withUnsafeBytes { $0.load(as: Float32.self) })  // little-endian on arm64
    case "fpe2": guard r.bytes.count >= 2 else { return nil }
        return Double((UInt16(r.bytes[0]) << 8) | UInt16(r.bytes[1])) / 4.0
    case "fp78": guard r.bytes.count >= 2 else { return nil }
        return Double((UInt16(r.bytes[0]) << 8) | UInt16(r.bytes[1])) / 256.0
    case "sp78": guard r.bytes.count >= 2 else { return nil }
        let raw = Int16(bitPattern: (UInt16(r.bytes[0]) << 8) | UInt16(r.bytes[1]))
        return Double(raw) / 256.0
    case "ui8 ", "si8 ": guard r.bytes.count >= 1 else { return nil }
        return Double(r.bytes[0])
    case "ui16": guard r.bytes.count >= 2 else { return nil }
        return Double((UInt16(r.bytes[0]) << 8) | UInt16(r.bytes[1]))
    default: return nil
    }
}

func formatNum(_ d: Double) -> String {
    d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d)
}
func show(_ k: String) -> String {
    guard let r = readKey(k) else { return "n/a" }
    if let d = decode(r) { return String(format: "%@ [%@]", formatNum(d), r.dataType) }
    return "raw \(Array(r.bytes.prefix(r.size))) [\(r.dataType)]"
}

print("=== amber-cool SMC probe (READ-ONLY) ===\n")

if let fnum = readKey("FNum"), let n = decode(fnum) {
    let count = Int(n)
    print("FNum (fan count) = \(count)  [\(fnum.dataType)]\n")
    for i in 0..<count {
        print("Fan \(i):")
        print("  actual  F\(i)Ac = \(show("F\(i)Ac"))")
        print("  min     F\(i)Mn = \(show("F\(i)Mn"))")
        print("  max     F\(i)Mx = \(show("F\(i)Mx"))")
        print("  target  F\(i)Tg = \(show("F\(i)Tg"))")
        print("  mode    F\(i)Md = \(show("F\(i)Md"))  (0=auto 1=manual 3=system)")
    }
    print("")
} else {
    print("Could not read FNum\n")
}

print("Ftst (AS unlock key) = \(show("Ftst"))")
print("F0Md alt-casing F0md = \(show("F0md"))\n")

let tempKeys = ["Te05","Te0S","Te09","Te0H","Tp01","Tp05","Tp09","Tp0D","Tp0H","Tp0e",
                "Tg0G","Tg0H","Tg0f","TC0P","TC0E","Ts0S","Tp0A","Tp0C","Tp0f","Tp0j"]
var temps: [(String, Double)] = []
for k in tempKeys {
    if let r = readKey(k), let d = decode(r), d > 0, d < 150 { temps.append((k, d)) }
}
if temps.isEmpty {
    print("No temps from sampled key set (key names are chip-specific; full enumeration needed).")
} else {
    let avg = temps.map { $0.1 }.reduce(0, +) / Double(temps.count)
    print("Temp sensors sampled (\(temps.count)):")
    for (k, v) in temps { print(String(format: "  %@ = %.1f°C", k, v)) }
    print(String(format: "  -> sampled average = %.1f°C", avg))
}

IOServiceClose(conn)
