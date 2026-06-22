# amber-temp — Research: How to control Mac fans properly

Research compiled 2026-06-22 for an Apple Silicon target (**MacBook Pro Mac16,8, Apple M4 Pro, macOS 26.5.1**).
Validated live on that machine with the read-only probe in [`probe/smc-probe.swift`](probe/smc-probe.swift).

---

## 0. TL;DR — the eight things that matter

1. **Fan control = reading/writing SMC keys via the `AppleSMC` IOKit service from userspace.** No kernel extension is ever needed.
2. **Reads need no privileges. Writes require root.** This forces a two-component design: an unprivileged menu-bar app + a root helper daemon.
3. **The modern, Apple-blessed way to ship that root helper is `SMAppService.daemon(...)`** (macOS 13+) embedded in the app bundle, reached over a code-signing-validated XPC connection. SMJobBless / `AuthorizationExecuteWithPrivileges` / setuid are deprecated or insecure.
4. **Apple Silicon needs the `Ftst` handshake.** A system daemon (`thermalmonitord`) owns the fans in "System Mode" (`F0Md`=3) and *silently ignores* direct writes. You must write `Ftst=1`, wait for `F0Md` to drop to 0 (~3–6 s), then write `F0Md=1` + `F0Tg`. Restore with `Ftst=0`. This is exactly why naive ports (e.g. Stats) "don't work on M3/M4+".
5. **Data formats differ by era.** Apple Silicon fan RPM and temps are 4-byte little-endian IEEE-754 floats (`flt `). Intel used fixed-point (`fpe2` RPM, `sp78` temps). Mode/`Ftst` are `ui8`.
6. **There is no single "CPU temperature".** The SoC exposes many per-cluster die sensors (`Tp*`/`Te*`/`Tf*` for CPU, `Tg*` for GPU), and **the key names change every chip generation.** A meaningful "CPU temp" is the average of the cluster group.
7. **The three modes are simple math, not magic.** 0–10 → linear interp between each fan's own min/max; custom RPM → clamp + write; temperature target → a linear ramp between two thresholds (NOT a PID), recomputed every 1–2 s off a smoothed sensor.
8. **Safety is the hard part and is non-negotiable.** Taking manual control *disables macOS's own emergency fan boost*. The helper must own a watchdog that reverts to auto if the app crashes/quits, re-establish on sleep/wake, and force max (or hand back to auto) on overheat.

---

## 1. Live validation on this Mac (M4 Pro, macOS 26.5.1)

The read-only probe confirms the entire substrate works and every data format decodes correctly:

```
FNum (fan count) = 2  [ui8 ]

Fan 0:  actual F0Ac = 3334.78 [flt ]   min 2317   max 7826   target 3333   mode 1 (manual)
Fan 1:  actual F1Ac = 3335.00 [flt ]   min 2317   max 7826   target 3333   mode 1 (manual)

Ftst = 1 [ui8 ]                         <- manual unlock currently ENGAGED
Temp cluster (Tp*/Te*) average ≈ 69 °C  (per-sensor 64–77 °C, all flt)
```

Findings:
- **2 controllable fans**, min ≈ **2317 RPM**, max ≈ **7826 RPM** (per-fan; here identical).
- **Writes provably work on this hardware/OS**: `F0Md`=1 and `Ftst`=1 mean manual control is active *right now* — set by the already-installed **Macs Fan Control** (`/Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite`). So the "M3/M4+ writes are broken" risk from the literature does **not** apply to this machine.
- `flt` decoding (fans + temps) and `ui8` decoding (mode, Ftst) are correct.
- **Coexistence caveat:** Macs Fan Control (and `FanBar.app`) are installed. Two apps writing SMC fan keys will fight. During amber-temp development, set Macs Fan Control to Auto or quit it.

---

## 2. The SMC substrate (IOKit protocol)

Fan control goes through the closed-source `AppleSMC` IOKit service. The userspace dance:

1. `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))`
2. `IOServiceOpen(service, mach_task_self_, 0, &conn)` → `io_connect_t`
3. `IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC=2, &in, 80, &out, &outSize)` — operation selector goes in the struct's `data8` field
4. `IOServiceClose(conn)`

**Selectors** (placed in `data8`): `kSMCReadKey=5`, `kSMCWriteKey=6`, `kSMCGetKeyInfo=9`, `kSMCGetKeyFromIndex=8`.

**The param struct is exactly 80 bytes.** ⚠️ **Gotcha proven during this research:** a Swift struct mirroring the C `SMCParamStruct` compiled to **76 bytes** — Swift does not guarantee C field layout and may repack. The kernel rejects anything ≠ 80. **Fix:** build the 80-byte buffer and poke fields at explicit C offsets (key@0, keyInfo.dataSize@28, keyInfo.dataType@32, result@40, data8@42, bytes@48). This is what the working probe does; the real app should either do the same or define the struct in a bridged C header.

**A read is two calls:** (1) get key info (selector 9) → returns `dataSize` + `dataType`; (2) read bytes (selector 5) with that `dataSize`. **A write is also info-first** (to learn the size the kernel will validate against), then selector 6 with the encoded payload.

**Data type encodings:**

| Type | Meaning | Decode |
|---|---|---|
| `flt ` | IEEE-754 float, 4 bytes **little-endian** | raw `memcpy`/`load(as: Float32)` — Apple Silicon fans & temps |
| `fpe2` | unsigned fixed-point 14.2 | value = raw/4 (to write: `rpm << 2`) — Intel fan RPM |
| `sp78` | signed fixed-point 8.8 | value = raw/256 — Intel temps |
| `ui8 ` | unsigned byte | as-is — `FNum`, `F0Md`, `Ftst` |
| `ui16`/`ui32` | unsigned int (big-endian payload) | as-is |

---

## 3. Fan keys & forced/manual mode

| Key | Type | Meaning |
|---|---|---|
| `FNum` | ui8 | number of fans |
| `F0Ac` | flt/fpe2 | fan 0 **actual** RPM (read-only) |
| `F0Mn` | flt/fpe2 | fan 0 recommended **min** RPM (guideline, not firmware-enforced) |
| `F0Mx` | flt/fpe2 | fan 0 recommended **max** RPM (guideline) |
| `F0Tg` | flt/fpe2 | fan 0 **target** RPM (what you command in manual mode) |
| `F0Md` | ui8 | fan 0 **mode**: 0=auto, 1=manual, 3=system (Apple Silicon default) |
| `FS! ` | bitmask | (Intel/legacy) global force register, bit N = fan N. `0x0000` = all auto |
| `Ftst` | ui8 | (Apple Silicon) force/test flag that unlocks manual control |

Replace `0` with the fan index for additional fans (`F1Tg`, …). Note `F0Mn`/`F0Mx`
are *guidelines* — the fan can physically spin outside them (observed max on M4 can exceed the reported `F0Mx`). Treat them as UI anchors, not hard limits.

**Forcing is always two steps:** (1) enter manual mode — Intel: set the fan's `FS!` bit; Apple Silicon: the `Ftst` handshake below — then (2) write the RPM to `F0Tg`. `F0Md=1` only flips the fan to manual; it does not itself set a speed. **Restore auto** with `F0Md=0` (or `FS!=0x0000` on Intel; `Ftst=0` on Apple Silicon).

---

## 4. Apple Silicon specifics (the `Ftst` handshake)

This is the single most important platform difference, documented by `agoodkind/macos-smc-fan` and confirmed by `exelban/stats` #2928 — and visible in our probe (`Ftst`=1 right now):

On Apple Silicon, `thermalmonitord` holds fans in **System Mode (`F0Md`=3)** and **silently rejects** writes to `F0Md`/`F0Tg`. The working unlock sequence:

1. Write **`Ftst = 1`** (diagnostic/force mode) → `thermalmonitord` relinquishes control.
2. Poll `F0Md` every ~100 ms; it transitions 3 → 0 after ~3–4 s (timeout ~10 s).
3. Write **`F0Md = 1`** (succeeds within ~4–6 s).
4. Write target RPM to **`F0Tg`**.

Hand back: **`Ftst = 0`** → fans return to System Mode 3. Caveats:
- **Sleep/wake resets `Ftst` to 0** in firmware → manual control silently evaporates on wake; you must listen for `NSWorkspace` wake notifications and re-establish (or fall back to auto).
- On some **M5** machines `Ftst` doesn't exist (`SmcNotFound 0x84`) and `F0md=1` (lowercase) writes succeed directly. Probe both casings.
- Key/mode casing varies by chip (`F0Md` upper on M4, `F0md` lower on some M5).

**Which Apple Silicon Macs have controllable fans:** MacBook Pro 14/16 (yes — our target), Mac mini, Mac Studio, Mac Pro, iMac. **MacBook Air is fanless** (monitor only, nothing to drive).

**Temperature sensors:** no single CPU register. Per-cluster die sensors, `flt`, **key names change every generation** (the same key can mean a different sensor across chips). On M4: E-cores `Te05, Te0S, Te09, Te0H`; P-cores `Tp01…Tp0e` (our probe read 11 valid CPU sensors, ~69 °C avg). GPU = `Tg*` group. Surface "CPU temp" = average of the CPU cluster group; smooth with an EMA before using as a control input. `exelban/stats` `Modules/Sensors/values.swift` has the best per-generation key map; full discovery = enumerate keys via selector 8 and filter `T*`.

---

## 5. The privilege boundary & helper architecture

**Read in-process (unprivileged); write through a root helper.** A bare `kSMCWriteKey` returns `kIOReturnNotPrivileged` without root.

**Recommended (macOS 13+):** a privileged **LaunchDaemon helper** embedded in the app bundle, registered via **`SMAppService.daemon(plistName:)`**, running as root, exposing narrow SMC verbs over an **XPC Mach service**. This is what `exelban/stats` migrated to in v3.0.2.

Bundle layout:
```
amber-temp.app/Contents/
  MacOS/amber-temp                              (menu bar app, unprivileged)
  Library/LaunchDaemons/<Label>.plist           (REQUIRED location SMAppService scans)
  Library/HelperTools/<Helper>                  (root helper binary)
```
Daemon plist keys: `Label`, `BundleProgram` (bundle-relative path to helper), `MachServices` (the XPC service name), `AssociatedBundleIdentifiers` (ties it to the app for the Login Items UI).

`register()` triggers a user-approval flow: the helper appears in **System Settings → General → Login Items & Extensions** and the user enables it (admin auth, since it's a daemon). Check `service.status`; on `.requiresApproval` call `SMAppService.openSystemSettingsLoginItems()`. (Unlike old SMJobBless, there is no single install-time password prompt — the user flips a switch.)

**Security (this is where it lives):**
- App → daemon: `NSXPCConnection(machServiceName:options:.privileged)`.
- Daemon validates every incoming connection with `connection.setCodeSigningRequirement(...)` (macOS 13+) using a requirement string pinning **same Developer ID team**:
  `identifier "co.welf.amber-temp" and anchor apple generic and certificate leaf[subject.OU] = "6Y24LA63S7"`
  (`setCodeSigningRequirement` does a *static* check; for full safety also validate the connection's **audit token** via `SecCode` — the PID is racy.)
- Validate **both directions**; keep the daemon's API surface minimal (`setFanMode`/`setFanSpeed`/`resetToAuto` only — never "run arbitrary command as root").

**Rejected alternatives:** SMJobBless (deprecated macOS 13), `AuthorizationExecuteWithPrivileges` (deprecated since 10.7), setuid root binary (notarization-hostile, footgun), installer-pkg-dropped daemon (works but leaves files outside the bundle, needs a separate installer — only justified for pre-13 support).

---

## 6. The three modes

All three compute a per-fan target RPM, then write it via the manual-mode path above. **Read `F0Mn`/`F0Mx` per fan and compute per fan** (the two MBP fans can differ; here both 2317–7826).

**Mode 1 — Scale 0–10** (TG Pro's percentage model):
```
target = F0Mn + (F0Mx − F0Mn) × (scale / 10)
```
0 → min, 10 → max, 5 → midpoint.

**Mode 2 — Custom RPM:** clamp typed value to `[F0Mn, F0Mx]` (never allow 0 / fan stop), write to `F0Tg`.

**Mode 3 — Temperature target** (linear ramp, **not PID** — none of Macs Fan Control / TG Pro / Stats use PID; the two-threshold ramp is stable and avoids hunting):
```
T_low, T_high derived from setpoint (e.g. target 65 → ramp 60→75)
if temp ≤ T_low:  target = F0Mn
if temp ≥ T_high: target = F0Mx
else:             target = F0Mn + (F0Mx − F0Mn) × (temp − T_low)/(T_high − T_low)
```
- Recompute every **1–2 s** (TG Pro default 2 s) off a **smoothed CPU-die average** (EMA over a few samples; never a single raw core sensor — too noisy).
- **Slew-limit** the target (ramp toward the computed value over a configurable time) to avoid audible fan pumping on momentary spikes.

---

## 7. Safety guardrails (mandatory)

1. **Always offer one-click "System / Auto"** — `F0Md=0` / `Ftst=0` hands fans fully back to macOS.
2. **Restore auto on quit AND crash.** Quit handler restores auto; because a crash skips it, **the root helper owns a watchdog**: it holds manual mode only while the app heartbeats it; miss the heartbeat → it reverts to auto on its own. (smcFanControl's known flaw: quitting doesn't reset fans. Don't repeat it.)
3. **Re-apply or revert on sleep/wake** — firmware resets `Ftst=0` on sleep; listen for wake and re-establish, or (safer) fall back to auto and let the user re-engage.
4. **Emergency override** — taking manual control disables macOS's own emergency boost. In temperature mode, force `F0Tg=F0Mx` above ~90–95 °C (or a critical SoC sensor); on any read failure / stale sensor / temp above ceiling, **drop straight back to auto** so the OS protects the machine. Never leave a hot machine pinned low.
5. **Fail-safe defaults** — default mode = System/Auto; clamp all targets to `[F0Mn, F0Mx]`; never write a key you didn't successfully read first.

**Polling cadence summary:** sensor read + recompute 1–2 s; `Ftst` unlock retry 100 ms / 10 s timeout; watchdog heartbeat sub-second to a few seconds.

---

## 8. Open-source references

- **`exelban/stats`** — mature Swift menu-bar monitor; SMC helper on `SMAppService` (`SMC/Helper/main.swift`, verbs `setFanMode`/`setFanSpeed`/`resetFanControl`). Best real-world helper architecture reference. (Its fan control is "legacy/Intel" and misses the `Ftst` handshake — read the architecture, not the AS write path.)
- **`agoodkind/macos-smc-fan`** — reverse-engineered M1–M5 `Ftst` unlock + working write. The reference for the Apple Silicon path.
- **`ProducerGuy/ThermalForge`** — open-source M1–M5 menu-bar + CLI fan control (does the handshake + watchdog). Closest end-to-end analog to amber-temp.
- **`beltex/SMCKit`** — Swift SMC plumbing (read/write/`callDriver`, models `notPrivileged`); good base, lacks `FS!`/`F0Tg` forcing.
- **`hholtmann/smcFanControl`** (`smc-command/smc.c`,`smc.h`) — canonical C struct/selector reference (Intel).
- **`alienator88/HelperToolApp`** — clean `SMAppService` + XPC + `setCodeSigningRequirement` structural sample (ignore its "run bash as root" demo API).
- **`acidanthera/VirtualSMC`** `Docs/SMCKeys.txt` — authoritative SMC key dictionary.
- CLI: `dkorunic/iSMC` (Go), `leaperone/smctl`, `charlie0129/smc_fan_util`.
- Closed-source behavior refs: **Macs Fan Control** (crystalidea), **TG Pro** (Tunabelly).

---

## 9. Risks & caveats

- **macOS 13+ floor** for `SMAppService` + `setCodeSigningRequirement`. Fine (target is 26).
- **Apple Silicon write fragility in general** (M3/M4+ regressions after some macOS point releases) — **not an issue on this machine** (writes proven working), but validate after major OS updates; helper may need re-enable after some updates.
- **Coexistence** — Macs Fan Control + FanBar are installed and will fight amber-temp over SMC. Quit/disable them while developing and testing.
- **Key names are chip-specific** — temp sensor maps must be per-generation or discovered by enumeration.
- **Notarization required** — Developer ID + hardened runtime (helper cannot be sandboxed; needs IOKit) + `xcrun notarytool` + staple, signed inside-out (helper first, then app), same Team ID both.

---

## 10. Primary sources

- agoodkind/macos-smc-fan · exelban/stats #2928, #1012, values.swift · ProducerGuy/ThermalForge
- hholtmann/smcFanControl smc.c/smc.h, #86 · beltex/SMCKit · acidanthera/VirtualSMC SMCKeys.txt
- Apple: `NSXPCConnection.setCodeSigningRequirement` docs · TN3127 (requirement strings) · dev forums 733046/721737
- theevilbit "SMAppService" · Bryson Tyrrell "macOS Apps With Embedded Daemons" · alienator88/HelperToolApp
- crystalidea Macs Fan Control (releases, supported-models, temperature-sensors) · Tunabelly TG Pro user guide
- btop #1653 (`flt` type) · fermion-star/apple_sensors · dkorunic/iSMC · leaperone/smctl · charlie0129/smc_fan_util
