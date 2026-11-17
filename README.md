# Haste Control

A native macOS menu-bar app for the **HyperX Pulsefire Haste Wireless** (model
PF002) — the original Haste Wireless, whose only official software (NGenuity)
is Windows-only.

* **Menu bar:** live battery level (mouse glyph fills with charge, optional %),
  charging indicator, low-battery and fully-charged notifications.
* **Quick popover:** battery, one-click DPI profile switching, polling rate.
* **Settings window** — feature parity with NGenuity:
  * DPI: 5 profiles (200–16 000 in steps of 100), enable/disable, indicator
    colour, active profile, lift-off distance (1/2 mm)
  * Polling rate 125 / 250 / 500 / 1000 Hz
  * Lighting: off, solid, breathing, spectrum cycle (custom palette), trigger
    fade — brightness and speed; stored onboard
  * Button remapping for all 6 buttons: mouse functions, any keyboard key,
    media keys, DPI cycle, firmware shortcuts, macros, disabled
  * Macro editor/recorder (up to 108 events, once / toggle / while-held)
  * Mouse charge-warning threshold, save to onboard memory, restore defaults
  * Firmware versions (mouse + receiver), battery voltage
* **`hastectl`** CLI for scripting (`hastectl battery --json`, `hastectl dpi set 2 1600`, …).

Everything is written to the mouse's onboard memory, so settings work on any
computer without the app running.

## Install

```bash
scripts/build-app.sh --install
```

Requires macOS 14+ and the Xcode Command Line Tools. No drivers, no special
permissions: the app talks to the mouse's vendor HID interface directly.

## Notes

* When the mouse is idle it sleeps and stops answering; the app shows the last
  known battery level and refreshes automatically when you move the mouse.
* Firmware "shortcut" button actions (Task Manager, Win+X, …) send Windows key
  combos. On macOS, map a keyboard key or a macro instead.

## How it works

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the HID protocol and
[docs/RESEARCH.md](docs/RESEARCH.md) for how it was reverse-engineered
(public NGenuity USB captures, decrypted stock firmware, live verification).

Unofficial project; not affiliated with HP or HyperX.
