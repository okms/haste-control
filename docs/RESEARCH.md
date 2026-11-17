# Research log

How the protocol in [PROTOCOL.md](PROTOCOL.md) was established.

## 1. The hardware on this machine

`ioreg` shows the dongle as `HP, Inc` / `HyperX Pulsefire Haste Wireless`,
VID `0x03F0` (1008) PID `0x028E` (654), bcdDevice `0x4106`. Three HID interfaces:

| Usage | Report descriptor summary |
|---|---|
| Generic Desktop / Mouse | 8 buttons, 16-bit X/Y, wheel |
| Generic Desktop / Keyboard + Consumer (report IDs 1, 2) | used for keyboard/media button remaps & macros |
| Vendor `0xFF00` / `0x01` | 64-byte in + 64-byte out, no report ID → **configuration channel** |

Model numbers seen in the wild for this product: 4P5D7AA (black), 4P5D8AA (white).
Sensor: PixArt PAW3335, 16 000 DPI max. MCU (mouse and dongle): Nordic nRF52833,
firmware written by Primax on the Nordic SDK (`main_ptx_with_usb.c`,
`primax_created/primax_middleware/*`, Enhanced ShockBurst PTX).

## 2. Prior art

| Source | What it gave us |
|---|---|
| [evan-razzaque/open-pulsefire-haste](https://github.com/evan-razzaque/open-pulsefire-haste) | Protocol notes + NGenuity USBPcap captures **for this exact mouse** (polling, DPI, LED, buttons, macros) |
| [santeri3700/hyperx_pulsefire_dart_reverse_engineering](https://github.com/santeri3700/hyperx_pulsefire_dart_reverse_engineering) | The original "NGenuity2" protocol notes for the Pulsefire Dart; the `D1` low-battery threshold opcode came from here |
| [radoslavchobanov/hyperx-pulsefire-battery](https://github.com/radoslavchobanov/hyperx-pulsefire-battery) | Linux tray app for the Dart, useful as a UX reference |
| [Perchanxe/HyperX-PulsefireHaste-Range-Fix](https://github.com/Perchanxe/HyperX-PulsefireHaste-Range-Fix) | Stock mouse (`03F0048E_STOCK.sfw`, fw 1.1.0.6) and dongle (`03F0028EMCU_STOCK.sfw`, fw 4.1.0.7) firmware images |
| [OpenRGB issue #2592](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/2592) | Confirms ID and the NGenuity feature set (lighting modes, brightness, charge warning) — no captures |

## 3. Firmware decryption

The `.sfw` files start with `SFW\x02` and look random, but a period scan
(`tools/firmware/xorscan.py`) shows a strong peak at **250 bytes**: the file is
XOR'd with a repeating 250-byte key. Taking the most common byte at each key
position and assuming the plaintext there is ASCII `'0'` (`xordec.py … 30`)
recovers an **Intel HEX** text file. `ihex2bin.py` turns it into a flat image:

* mouse app: `0x39000 – 0x5066B` (Thumb-2, nRF52833)
* dongle app: `0xA000 – 0x1420B`

Disassembly (Apple `objdump --triple=thumbv7em-none-eabi` on a `.incbin`
object) shows the vendor-report dispatcher as a chain of
`ldrb r0,[r4]; cmp r0,#op` blocks. Handled opcodes:

* reads: `50 51 52 53 54 55 56 57 59 5A`
* writes: `D0 D1 D2 D3 D4 D5 D6 D9 DA DB DE DF` (+ `DC` in a separate path)

`DF AA 00` copies 13 bytes of defaults and clears six macro tables — i.e. a
factory reset. `57 13 01 00` returns an 8-byte identifier. `5A N k 3c`
returns stored LED frame packet `k` for an `N`-frame effect.

The firmware itself is HP/HyperX property and is **not** committed here; only
the analysis scripts are. SHA-256 of the stock images analysed:

```
1e4e0d518bb80867d0e35e6165d02350e1402653cd876eeb80363edf140e21b6  03F0048E_STOCK.sfw
014780078142fc3d77229186e315f279d851dc5b255acdc39c8a479630b4137a  03F0028EMCU_STOCK.sfw
```

## 4. Live verification on macOS (2026-11-17)

`tools/hxprobe.swift` opens the `0xFF00` interface through IOHIDManager and
sends raw packets. Results on the attached mouse (fw 1.1.0.7, dongle 4.1.0.6):

* `51` → 78 %, discharging, warning 10 %, 3986 mV
* `D1 … 0f` → heartbeat byte 6 becomes `0f`; restored to `0a`
* `D0 … 03` → `50 03`[53] becomes `03`; restored to `02` (500 Hz)
* `D3 00 00 01 02` → `53`[4] = 2
* Sweep of `40–5F`: only `46 50 51 52 53 54 56 59` reply with data;
  everything else replies `02 ec ac`
* Unsolicited `FF 03 …` reports arrive on DPI change / wake
* Every write opcode used by the app acknowledges with `02 ec ac`:
  `D2 D3 D4 D5 D6 D9 DA DB DE` (session 2, mouse awake)
* Lighting round-trip: solid `00ff00` → `59` = N 1, `5A 01 00` frame 0 = `00 ff 00`;
  breathing blue speed 50 → `59` = N 0x41, frames match the capture curve
* Button round-trip: forward → key A → `54` shows `02 04`; macro bind → `04`
* `56 <btn>` returns an empty header even with a macro stored — macro
  read-back needs other parameters (unknown)
* All test changes were restored (lighting off, forward = Forward)

## Not yet confirmed

* `DB 55` exact meaning (firmware stores 6/4 into two state bytes)
* Heartbeat bytes 7, 8, 11, 12
* Whether `DE FF` is required for polling-rate persistence across power cycles
  (NGenuity does send it)
