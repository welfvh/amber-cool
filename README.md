# amber-temp

A simple macOS menu bar app to control your Mac's fans, with three distinct modes:

1. **Scale 0–10** — coarse slider from quiet (min) to max.
2. **Custom RPM** — set an exact fan speed.
3. **Temperature target** — pick a temperature; amber-temp drives the fans to hold it.

Status: **v1 built** — SMC core, `fanctl` CLI, a persistent root daemon, and a signed menu bar app. The fan-write path needs root; engage it via the installer (one `sudo`). See:
- [`RESEARCH.md`](RESEARCH.md) — how Mac fan control actually works (SMC, Apple Silicon, signing, safety), validated live on an M4 Pro.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — recommended design + phased build plan.
- [`docs/founding/00-vision.md`](docs/founding/00-vision.md) — original vision (verbatim).
- [`probe/smc-probe.swift`](probe/smc-probe.swift) — working **read-only** SMC probe (no root). Build: `swiftc -O probe/smc-probe.swift -o probe/smc-probe -framework IOKit`.

## Key facts (Apple Silicon)
- Fan control = read/write SMC keys via the `AppleSMC` IOKit service. No kext.
- **Reads need no root; writes do** → unprivileged menu-bar app + root helper (`SMAppService` daemon + XPC).
- Apple Silicon needs the **`Ftst` handshake** to take manual control from `thermalmonitord`.
- Fan/temp values are little-endian floats (`flt `); mode/`Ftst` are `ui8`.
- Safety is mandatory: helper-owned watchdog reverts to macOS auto on app crash/quit; emergency override on overheat.

⚠️ Coexistence: Macs Fan Control / FanBar (if installed) also write SMC fan keys and will conflict — the installer stops them.

## Build & run

```bash
# Read-only status (no root needed):
swift build -c release && ./.build/release/fanctl read

# Instant full blast (stops Macs Fan Control first, then pins fans to max).
# One-shot; holds until sleep. Revert with: sudo ./.build/release/fanctl auto
killall "Macs Fan Control" 2>/dev/null; sudo ./.build/release/fanctl max

# Make it a persistent service (survives reboot/sleep/crash):
sudo ./daemon/install.sh max         # or: "scale 7", "rpm 4000", "temp 65"

# Change mode any time (no root — file is made user-writable by the installer):
echo 'scale 7' > /usr/local/etc/amber-temp/mode

# Menu bar app (live status + mode switching; drives the daemon):
./app/bundle.sh && open build/amber-temp.app

# Stop everything, restore macOS auto:
sudo ./daemon/uninstall.sh
```

## Architecture (v1)

- **`AmberTempSMC`** — shared SMC read/write core (Ftst handshake, codecs, 3-mode math, M4 temp sensors).
- **`fanctl`** — CLI: reads unprivileged; `scale`/`rpm`/`max`/`temp`/`auto`/`daemon` require root.
- **daemon** — `fanctl daemon` as a root LaunchDaemon, holding the mode from a user-writable config file (`/usr/local/etc/amber-temp/mode`); re-engages after wake, emergency-max on overheat, restore-auto on stop.
- **menu bar app** — SwiftUI `MenuBarExtra`, reads SMC directly for live status, writes the config file to switch modes. Signed with Developer ID.

v1 uses a LaunchDaemon + config file (works today, no notarization needed to run locally). The `SMAppService` + XPC self-contained-helper packaging described in `ARCHITECTURE.md` is the v2 hardening path (no Terminal, code-signing-validated IPC).

