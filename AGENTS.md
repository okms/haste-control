# AGENTS.md

Instructions for AI coding agents working in this repository. The full guide is
[CLAUDE.md](CLAUDE.md); this file mirrors the essentials for agents that read
`AGENTS.md`.

## What this is

A native macOS menu-bar app (`HasteBar`, shipped as "Haste Control.app") and CLI
(`hastectl`) for the HyperX Pulsefire Haste Wireless mouse (PF002), built on a
reverse-engineered HID protocol library (`HasteKit`).

## Commands

```bash
swift build && swift test           # build everything, run protocol tests
scripts/build-app.sh [--install]    # package dist/Haste Control.app
.build/debug/hastectl status        # live check against the mouse
HASTE_SNAPSHOT=/tmp/snap .build/debug/HasteBar   # render UI to PNGs, then quit
```

## Rules

1. `docs/PROTOCOL.md` is the source of truth for the wire format. Update it
   (with provenance markers ✅ verified / 📼 capture / 🔬 firmware) whenever you
   learn or change something.
2. Use `@ViewState` instead of SwiftUI `@State` (CLT toolchain lacks the
   SwiftUI macro plugin). Don't use other SwiftUI macros.
3. Keep the test target in Swift 6 language mode.
4. The mouse ignores requests while asleep; check link state (`46`) first and
   handle `HasteError.timeout` as "asleep", not as a failure.
5. Never send `DF` (factory reset) or flash firmware without the user's
   explicit request. Restore any setting you change while experimenting.
6. Never commit vendor firmware images or other proprietary binaries.
7. Encoders must stay byte-identical to the NGenuity captures covered in
   `Tests/HasteKitTests/ProtocolTests.swift`.
