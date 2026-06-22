# amber-temp — Recommended Architecture & Build Plan

Derived from [`RESEARCH.md`](RESEARCH.md). Target: Apple Silicon, macOS 26 (floor macOS 13).
Distribution: Developer ID outside the App Store (Potential, Inc. — Team `6Y24LA63S7`).

---

## 1. Components

```
┌─────────────────────────────┐         XPC (validated)        ┌──────────────────────────┐
│  amber-temp.app             │  ───────────────────────────▶  │  amber-temp Helper (root)│
│  • MenuBarExtra UI          │   setFanMode / setSpeed /      │  • SMAppService daemon   │
│  • mode + policy logic      │   resetToAuto / heartbeat      │  • SMC read+WRITE        │
│  • reads SMC directly       │  ◀───────────────────────────  │  • Ftst handshake        │
│    (unprivileged)           │      fan/temp snapshots        │  • WATCHDOG (auto-revert)│
│  • LSUIElement, no Dock     │                                │  • not sandboxed         │
└─────────────────────────────┘                                └──────────────────────────┘
```

- **App** (unprivileged): owns UI, the active mode, the control loop (temperature ramp), and reads SMC directly (reads need no root). It never writes SMC; it asks the helper.
- **Helper** (root LaunchDaemon via `SMAppService.daemon`): the only writer. Performs the `Ftst` handshake, writes `F0Md`/`F0Tg`, and runs the safety watchdog. Minimal XPC surface.

Why split: SMC writes require root; everything else doesn't. Keep privilege in the smallest possible box.

## 2. Bundle layout & registration

```
amber-temp.app/Contents/
  MacOS/amber-temp
  Library/LaunchDaemons/co.welf.amber-temp.helper.plist
  Library/HelperTools/co.welf.amber-temp.helper
```
- Register: `SMAppService.daemon(plistName: "co.welf.amber-temp.helper.plist").register()`.
- Handle `.requiresApproval` → `SMAppService.openSystemSettingsLoginItems()` with in-app guidance ("enable amber-temp helper in Login Items").
- Plist: `Label`, `BundleProgram=Contents/Library/HelperTools/...`, `MachServices={co.welf.amber-temp.helper:true}`, `AssociatedBundleIdentifiers=[co.welf.amber-temp]`.

## 3. Shared SMC core (`SMCKit.swift`)

One small module, used read-only in the app and read+write in the helper:
- Open/close `AppleSMC`; `call()` via `IOConnectCallStructMethod`.
- **80-byte param buffer at explicit C offsets** (do NOT trust Swift struct layout — proven to mispack to 76 bytes; see probe). Or bridge a C header struct. Either is fine; offsets are the safe default.
- `read(key) -> (type, bytes)` (info-first then read); `write(key, bytes)` (info-first then write, root only).
- Decoders/encoders for `flt `, `fpe2`, `sp78`, `ui8 `, `ui16`.
- Fan model: `FNum`, and per fan `F{i}{Ac,Mn,Mx,Tg,Md}`.
- Temp model: per-generation key map (start with M-series `Tp*/Te*/Tf*`, `Tg*`); compute cluster averages; optional key enumeration (selector 8) for discovery.

The probe (`probe/smc-probe.swift`) is the validated read half — lift its buffer/offset/decode logic verbatim.

## 4. Write path — Ftst handshake state machine (helper)

```
engageManual():
  if Ftst exists: write Ftst=1; poll F0Md every 100ms until ==0 (timeout 10s)
  write F{i}Md = 1 for each fan
  -> state = MANUAL
setTarget(rpm_per_fan): clamp to [F{i}Mn, F{i}Mx]; write F{i}Tg
disengage(): write F{i}Md=0; if Ftst exists write Ftst=0  -> state = AUTO
```
Probe both `F0Md`/`F0md` casings. On `Ftst` absent (some M5), skip step 1.

## 5. Three modes (app-side policy → helper writes)

- **Scale 0–10:** per fan `target = Mn + (Mx−Mn)·(scale/10)`.
- **Custom RPM:** clamp to `[Mn, Mx]`, never 0.
- **Temperature target:** linear ramp `Mn→Mx` over `[setpoint−m, setpoint+m]`, recomputed every 1–2 s off an **EMA-smoothed CPU cluster average**, **slew-limited** toward the new target. App computes the RPM and calls `setTarget`; only the helper writes.

## 6. Safety (helper-owned where it counts)

- **Watchdog:** helper holds manual only while the app heartbeats (e.g. every 2 s). Miss N beats → `disengage()` to auto. Survives app crash.
- **Quit:** app calls `resetToAuto` on terminate; helper also auto-reverts via watchdog.
- **Sleep/wake:** `Ftst` resets on sleep → on wake either re-engage or fall back to auto (default: fall back, require re-engage).
- **Emergency:** temperature mode forces `Mx` above ~90–95 °C; any read failure / stale sensor → `disengage()` to auto. Never pin a hot machine low.
- **Defaults:** boot into System/Auto; clamp everything; write only previously-read keys.

## 7. UI (MenuBarExtra)

- Menu bar item shows current temp (cluster avg) + RPM, amber-styled.
- Mode picker (System / 0–10 / Custom RPM / Temp target) — radio, mutually exclusive.
- 0–10: stepper/slider. Custom: RPM field (clamped). Temp: setpoint field + margin.
- Prominent **"System (Auto)"** reset. Status line: helper state, fan actual vs target.
- `LSUIElement` (no Dock icon).

## 8. Signing / notarization (per Welf's release flow)

- Developer ID Application: Potential, Inc. (`6Y24LA63S7`), hardened runtime (`--options runtime --timestamp`).
- **Helper NOT sandboxed** (needs IOKit/root); app need not be sandboxed (not App Store).
- Sign **inside-out**: helper first, then app. Same Team ID both (XPC requirement string depends on it).
- `xcrun notarytool` (local keychain profile "notary") + staple. Verify `codesign -dv --verbose=4` on the embedded helper.

## 9. Coexistence

Macs Fan Control + FanBar are installed and will fight over SMC. amber-temp should detect a foreign manual state on launch (probe shows `F0Md`=1 / `Ftst`=1 set by another app) and warn / offer to take over. For dev: quit Macs Fan Control + FanBar first.

## 10. Phased build plan (each step verifiable)

1. **De-risk write (CLI, sudo).** Tiny CLI: `Ftst=1` → wait `F0Md→0` → `F0Md=1` → set `F0Tg` to a safe value → read back `F0Ac` to confirm movement → restore auto. → *verify: fan RPM visibly changes, then returns to auto.* (Macs Fan Control quit during this.)
2. **SMC core module** (read+write+encoders) extracted from probe + step 1. → *verify: unit round-trips on known keys.*
3. **Root helper via `SMAppService` + XPC**, verbs `setFanMode/setFanSpeed/resetToAuto/heartbeat`, code-signing requirement validation, watchdog. → *verify: app drives fan through helper; killing the app reverts to auto within the watchdog window.*
4. **Menu bar app + 3 modes + control loop + safety** (sleep/wake, emergency, clamps). → *verify each mode on-device against actual RPM; temp mode holds setpoint; overheat forces max.*
5. **Sign + notarize + staple**; coexistence detection. → *verify: clean Gatekeeper launch on this Mac; helper enables in Login Items.*

## 11. Open decisions (for Welf)

- **Build it, or stop at research?** You already run Macs Fan Control + FanBar. amber-temp's value = amber-ecosystem fit + your exact 3-mode UX. Confirm before I build.
- **App Store ever?** If no (recommended for a fan tool), Developer ID + unsandboxed = simplest. App Store is effectively impossible for SMC writes.
- **Amber visual integration** — standalone menu bar app, or fold into an existing amber surface (amber-overlay / okay-claude menu bar)?
- **Bundle id / name** — assumed `co.welf.amber-temp`; confirm.
