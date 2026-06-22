# amber-temp — Founding Vision (verbatim)

> Captured 2026-06-22. Raw, unedited. This file preserves the original ask and is never rewritten.

## The ask (verbatim)

> amber-temp: a simple mac menu bar app that controls your fans. you can set it on a scale of 0-10, custom rpm, as well as temperature targets (each of these are distinct modes). research how to do this properly.

## Reading

A simple macOS menu bar app to control the Mac's fans, with three **distinct modes**:

1. **Scale 0–10** — a coarse slider, 0 = quietest/min, 10 = max.
2. **Custom RPM** — type an exact fan speed.
3. **Temperature target** — set a temperature to hold; the app drives the fans to keep it.

"research how to do this properly" — do the engineering homework first (SMC internals, Apple Silicon
realities, privileged-helper architecture, signing, safety) before writing the app.
