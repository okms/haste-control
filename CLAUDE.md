# Haste Control — macOS utility for the HyperX Pulsefire Haste Wireless (PF002)

Native macOS menu-bar app + CLI that replaces HyperX NGenuity (Windows-only)
for the original Pulsefire Haste **Wireless** (model PF002, 4P5D7AA/4P5D8AA).

## Layout

| Path | What |
|---|---|
| `Sources/HasteKit/` | Protocol library: `Protocol.swift` (packet builders/parsers), `Lighting.swift` (LED frame tables), `Macro.swift`, `HIDKeyboard.swift`, `HIDTransport.swift` (IOKit), `HasteMouse.swift` (async API) |
| `Sources/HasteBar/` | SwiftUI menu-bar app (`MenuBarExtra` + settings `Window`), state in `MouseStore.swift` |
| `Sources/hastectl/` | CLI (`hastectl status`, `dpi set 2 1600`, `polling 1000`, `raw 51`, …) |
| `Tests/HasteKitTests/` | Swift Testing; encoders checked byte-for-byte against NGenuity USB captures |
| `docs/PROTOCOL.md` | **Authoritative protocol reference** — update it when you learn something |
| `docs/RESEARCH.md` | Sources, firmware decryption method, verification log |
| `tools/hxprobe.swift` | Minimal raw-packet prober (`swift tools/hxprobe.swift "51" "50 05"`) |
| `tools/firmware/` | `.sfw` decryptor (XOR-250 → Intel HEX → bin) and pcapng dumper |
| `scripts/build-app.sh` | Builds `dist/Haste Control.app` + `dist/hastectl` (`--install` → /Applications) |

## Build / test

```bash
swift build                    # debug, all targets
swift test                     # protocol tests (no hardware needed)
scripts/build-app.sh           # release .app bundle in dist/
.build/debug/hastectl status   # talk to the real mouse
HASTE_SNAPSHOT=/tmp/snap .build/debug/HasteBar   # render popover + every settings page to PNG, then quit
```

## Toolchain gotchas (Command Line Tools only, Xcode license not accepted)

* `xcodebuild` is unavailable; everything is SwiftPM. Xcode.app exists but its
  license isn't accepted, so don't rely on `DEVELOPER_DIR=…Xcode.app`.
* The macOS 27 SDK makes SwiftUI `@State` a macro whose plugin ships only with
  Xcode. **Use `@ViewState`** (alias in `Sources/HasteBar/Compat.swift`) instead
  of `@State`. Avoid `@Entry`, `@Previewable`, `#Preview`, `@Animatable`.
* Swift Testing macros break if the test target uses Swift 5 language mode —
  keep the test target in Swift 6 mode (library/app targets use `.v5`).
* CLI tools must spin `RunLoop.main` (IOKit delivers input reports there).

## Protocol essentials (details in docs/PROTOCOL.md)

* Vendor interface: usage page `0xFF00`, 64-byte output reports, no report ID,
  replies arrive as input reports echoing `op, b1`.
* Dongle `03F0:028E`, cable `03F0:048E`. Prefer the cable when both exist.
* **When the wireless mouse sleeps, the dongle silently drops every request
  routed to the mouse.** Always check `46` (answered by the dongle) first; the
  dongle pushes `FF 03 …` when the mouse wakes.
* Writes are RAM-only until `DE FF` (save all) / `DE 03` (save DPI).
* `DF AA 00` is a factory reset found in firmware — never send it casually.

## Conventions

* Never commit HyperX firmware images (`*.sfw`, `*.bin` are git-ignored).
* Any new opcode or field: verify on hardware with `hastectl raw` / `hxprobe`,
  add a test, and document it in `docs/PROTOCOL.md` with ✅/📼/🔬 provenance.
* Restore anything you change on the user's mouse during experiments.
* Commit with clear messages as you go.
