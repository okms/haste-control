# HyperX Pulsefire Haste Wireless (PF002) — HID protocol

Everything here was either verified against a real mouse on macOS (marked ✅),
taken from published NGenuity USB captures (📼), or read out of the decrypted
mouse firmware (🔬). See [RESEARCH.md](RESEARCH.md) for sources and method.

## Transport

| | Wireless (dongle) | Wired (USB-C cable) |
|---|---|---|
| VID:PID | `03F0:028E` | `03F0:048E` |
| Config interface | #2, usage page `0xFF00`, usage `0x01` | #2, usage page `0xFF00` |
| Report size | 64 bytes in / 64 bytes out, **no report ID** | same |

* Send: `IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, buf, 64)` ✅
* Receive: asynchronous input reports on the same interface ✅
* No TCC / Input-Monitoring permission is needed on macOS for this vendor
  usage page (verified on macOS 27) ✅
* The dongle relays packets to the mouse over the 2.4 GHz link. If the mouse is
  asleep, requests that need the mouse still get answered by the dongle (with
  cached data or `02 ec ac`).

### Packet framing

```
byte 0   opcode
byte 1   sub-command / index
byte 2   sub-command / index
byte 3   payload length (number of bytes after byte 3)
byte 4…  payload
```

Every request gets a reply whose first bytes echo the request. A reply of
`<op> <b1> <b2> 02 ec ac` means "no data" — it is returned both for unknown
read opcodes **and** as the normal acknowledgement for most write opcodes ✅.

## Read requests (host → device, device answers with same opcode)

| Request | Reply | Notes |
|---|---|---|
| `46` | `46 00 00 01 <awake>` | Connection: byte3 `01` = wireless (byte4 1 = mouse awake/linked, 0 = asleep); `02` = wired ✅ |
| `50` | `50 00 00 3c <pid lo/hi> <vid lo/hi> <fw ×4> …"HyperX Pulsefire Haste Wireless"` | **Dongle/receiver** info. fw bytes 8–11 little-endian → `06 00 01 04` = 4.1.0.6 ✅ |
| `50 05` | same layout as `50` | **Mouse** info via the link: PID `048E`, fw `07 00 01 01` = 1.1.0.7 ✅ (undocumented elsewhere) |
| `50 03` | full settings dump (see below) | ✅ |
| `50 04` | `50 04 00 01 01` | unknown, constant ✅ |
| `51` | heartbeat / battery (see below) | ✅ |
| `52` | LED "direct" settings | `[7]` brightness, `[8..10]` RGB ✅ |
| `53` | DPI settings (see below) | ✅ |
| `54` | button assignments, 6 × 3 bytes from `[4]` | ✅ |
| `55 <n>` | macro metadata for button n | 🔬 returns `02 ec ac` when no macro ✅ |
| `56 <btn>` | macro data for button | 🔬 |
| `57 13 01 00` | 8 bytes, e.g. `02 02 9a ad 60 26 01` | 🔬 probably radio/pairing id ✅ |
| `59` | `59 00 00 03 55 <frameCount> 23` | onboard LED effect header (mirrors `D9`) ✅ |
| `5a <frameCount> <pkt 0-5> 3c` | 60 bytes of stored effect frames | 🔬✅ |

### `51` heartbeat

```
51 00 00 09 | 4e | 00 | 0a | 1b | 00 | 92 0f | 02 | 04
            batt chg  warn  ?    ?   mV(LE)   ?    ?
```

| idx | meaning |
|---|---|
| 4 | battery % (0–100) ✅ |
| 5 | 0 = discharging, 1 = charging, 2 = fully charged ✅/📼 |
| 6 | low-battery warning threshold % (set with `D1`) ✅ |
| 9–10 | battery voltage in mV, little-endian (`0x0f92` = 3986 mV) ✅ (inferred, tracks %) |

### `53` DPI settings

```
53 00 00 21 | act | mask | 01 00 | a0 00 | 10 00 | dpi0 lo hi … dpi4 lo hi | rgb0 … rgb4 | lod
```

| idx | meaning |
|---|---|
| 4 | active profile index 0–4 |
| 5 | enabled-profile bitmask (bit n = profile n) |
| 8 | max DPI step (`0xa0` = 160 → 16 000 DPI) |
| 12–21 | 5 × little-endian DPI steps; **DPI = step × 100** |
| 22–36 | 5 × RGB indicator colours |
| 37 | lift-off distance: 1 = low (1 mm), 2 = high (2 mm) |

### `50 03` full settings dump

```
50 03 00 31 | 04 00 04 00 10 00 | dpi steps ×5 (LE16) | rgb ×5 | buttons 6×3 | polling
idx          4                   10                    20       35            53
```

Byte 53 = polling rate code (`0`=125, `1`=250, `2`=500, `3`=1000 Hz) ✅.

### Button action triple (in `54` and `50 03`)

`<type> <code> <mask>` where mask = `1<<n` for mouse/media, otherwise = code.

## Write requests

All are acknowledged with `<op> … 02 ec ac`. Changes take effect immediately
but live in RAM until saved with `DE` (**except** where noted).

| Packet | Effect |
|---|---|
| `D0 00 00 01 <rate>` | Polling rate 0=125, 1=250, 2=500, 3=1000 Hz ✅ |
| `D1 00 00 01 <pct>` | Low-battery warning threshold (NGenuity: 5–25 %) ✅ (reflected in `51`[6]) |
| `D2 00 00 08 <rgb> <rgb> <bri> 00` | Direct LED colour; reverts to onboard effect after ~2 s unless re-sent 📼 |
| `D2 00 30 08 <rgb> 000000 <bri> <speed>` | Configure **Fade/Trigger** effect; speed byte = `max(0, 63 − round(0.64·s))` for s∈0…100 📼 |
| `D2 00 40 08 ffffff 000000 64 00` | "store" packet NGenuity sends before non-fade effects 📼 |
| `D3 00 00 01 <idx>` | Select active DPI profile ✅ |
| `D3 01 00 01 <mask>` | Enabled-profile bitmask 📼 |
| `D3 02 <idx> 02 <lo> <hi>` | DPI step for profile (DPI/100) 📼 |
| `D3 03 <idx> 03 <r> <g> <b>` | Profile indicator colour 📼 |
| `D3 05 00 01 <lod> <lod>` | Lift-off distance 1/2 mm 📼 |
| `D4 <btn> <type> 02 <code> 00` | Button assignment 📼 |
| `D5 <btn> 00 05 <events> 00 <repeat> 00 00` | Bind macro to button. repeat 0 = once, 2 = toggle, 3 = while held 📼 |
| `D6 <btn> <seq> <cnt> <events…>` | Macro data chunk (≤ 6 events) 📼 |
| `D9 00 00 03 55 <frameCount> 23` | Commit onboard LED effect header 📼 |
| `DA <frameCount> <pkt 0-5> 3c <20 × rgb>` | Onboard LED effect frame table 📼 |
| `DB 55` | Sent by NGenuity after `D9` (firmware: sets two internal state bytes) 📼🔬 |
| `DE 03` | Save DPI settings to flash 📼 |
| `DE FF` | Save **all** settings to flash 📼 |
| `DF AA 00` | 🔬 **Factory reset** (copies default tables, clears 6 macro slots). Not exercised. |

### Physical buttons

`0` left · `1` right · `2` middle · `3` back · `4` forward · `5` DPI button

### Assignment types (`D4` byte 2)

| type | meaning | codes |
|---|---|---|
| 0 | disabled | 0 |
| 1 | mouse | 1 L · 2 R · 3 M · 4 back · 5 forward |
| 2 | keyboard | USB HID keyboard usage (page 0x07) |
| 3 | media | 0 play/pause · 1 stop · 2 prev · 3 next · 4 mute · 5 vol− · 6 vol+ |
| 4 | macro | code = physical button index |
| 5 | Windows shortcut | 1 Task Mgr · 2 Win+X · 3 Show desktop · 4 Win+Tab · 5 Alt+F4 · 6 cut · 7 copy · 8 paste |
| 7 | DPI toggle | 8 |

Factory defaults (read from the device): L=`1/1`, R=`1/2`, M=`1/3`, back=`1/4`,
fwd=`1/5`, DPI=`7/8`.

### Onboard LED effects

The mouse plays a looping table of up to **120 RGB frames** (6 `DA` packets ×
20 colours). The frame count *is* the speed. Colours are pre-multiplied by
brightness (`c · bri / 100`).

| Effect | frame count N | frames |
|---|---|---|
| Solid | 1 | the colour |
| Breathing | `floor(120 − 1.09·s)` (s = speed 0–100) | `floor(c · sin(π·i/(N−1)))` |
| Spectrum cycle | `floor(120 − 0.4·s)` | linear interpolation around the closed palette, `t = i·M/(N−1)` |
| Fade / trigger | 1, all frames zero | parameters in `D2 00 30` |
| Off | 1, all zero | |

Apply sequence (as NGenuity does it):

```
[D2 00 40 …  or  D2 00 30 … for fade]
DA N 00 3c …  ×6 packets (00…05)
D9 00 00 03 55 N 23
DB 55
DE FF
```

### Macros

Event encodings (delay = milliseconds to wait *after* the event, LE16):

```
keyboard (10 B): 1a <modifiers> <k1> <k2> <k3> <k4> <k5> <k6> <delay lo> <delay hi>
                 key-up = all six keys 0
mouse    (5 B):  25 <button mask> <wheel i8> <delay lo> <delay hi>
                 button mask 01 L 02 R 04 M 08 back 10 fwd; release = mask 0
modifiers: 01 LCtrl 02 LShift 04 LAlt 08 LGui 10 RCtrl 20 RShift 40 RAlt 80 RGui
```

Upload:

```
D4 <btn> 04 02 <btn> 00
D6 <btn> <floor(3n/2)> <count | 0x80 if n odd> <≤6 events>   for n = 0…
D5 <btn> 00 05 <total events> 00 <repeat> 00 00
DE FF
```

Max ≈ 108 events (18 packets).

## Unsolicited events

`FF 03 <profile> <charging> <awake> 00 00 <buttons> <shortcut>` is pushed by
the dongle whenever the DPI profile, charge state, sleep state or buttons
change ✅. byte 4 = 0 → going to sleep, 1 → woke up.
