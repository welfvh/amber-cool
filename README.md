# amber-temp

A simple macOS menu bar app to control your Mac's fans, with three distinct modes:

1. **Scale 0–10** — coarse slider from quiet (min) to max.
2. **Custom RPM** — set an exact fan speed.
3. **Temperature target** — pick a temperature; amber-temp drives the fans to hold it.

Status: **research complete, not yet built.** See:
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

⚠️ Coexistence: Macs Fan Control / FanBar (if installed) also write SMC fan keys and will conflict — disable them while running amber-temp.
