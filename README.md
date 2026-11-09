# FeiXunMai（VibeDeck）

**English** · [简体中文](README.zh-CN.md)

Turn a **Feixun T1/N1 Bluetooth voice remote** (RTL_618) into a wireless microphone and air mouse for the Mac — the same idea as [Wireless Mic SayAll](https://github.com/HD838A/remote-mic-app) and OpenAI × Work Louder's [Codex Micro](https://worklouder.cc/codex-micro): one push-to-talk key to drive an AI assistant, a handful of physical keys to drive the computer.

The whole installer is about 300 KB and built entirely on Apple frameworks (Swift / AppKit / CoreBluetooth / AVFoundation), with no third-party Swift dependencies. The project owes a lot to remote-mic-app's public notes — see [Acknowledgements](#acknowledgements).

![FeiXunMai settings window](docs/screenshot.png)

## Features

**Voice — hold to talk, release to stop**

- Audio arrives over the remote's BLE Kehwin private channel as mSBC 16 kHz, is decoded locally, and is routed into a virtual microphone.
- On voice start the app synthesizes an Fn hold (configurable: ⌘ / ⌥ / F5 / toggle) to open voice input in apps such as Doubao or WeChat Input.
- The system default input switches to the virtual mic for the duration of the call and is restored afterwards — remote voice and keyboard dictation do not fight over the same device.
- Ships **FeiXunV 2ch**, a virtual audio device with a USB transport type, so apps that filter out "virtual" devices (Doubao, for example) still list it.

**Keys**

- D-pad = mouse movement (hold to accelerate); OK = left click (hold to drag).
- Menu = Return; Back = Delete (hold to repeat); Home = Esc; OTT power = Paste ⌘V.
- Every key is remappable (Return / Esc / Delete / Copy / Paste / Left / Right / Mission Control / Lock Screen / Disabled).
- Volume keys pass through to macOS; TV power is infrared and never reaches the Mac.
- The remote's F5 HID echo is swallowed, so it never triggers system dictation or another voice tool.

**Other**

- Menu bar app plus the VibeDeck console (Overview / Voice / Capsules / Keys / Stats).
- Local stats only (today's voice count and duration), reset by date; nothing leaves the Mac.
- 30-second keepalive, subscription self-check, and sleep/wake recovery, so it still answers after hours on the desk.

## VibePad (Android phone)

The companion app (separate `vibepad/` project) turns a phone into a trackpad plus a
wireless microphone. The two links are independent:

- **trackpad** — the phone registers as a standard Bluetooth HID mouse/keyboard, so the
  Mac needs no client at all;
- **voice** — a dedicated BLE GATT service (`7A1B0001-…`) streams 8 kHz ADPCM, which the
  Mac decodes into FeiXunV 2ch.

Gestures:

| Gesture | Action |
|---|---|
| One-finger move / tap | Move pointer / left click |
| Two-finger swipe | Scroll (natural direction, matching macOS) |
| Two-finger tap | Right click |
| Hold still ~0.35 s, then move | Press and drag (no double-tap drag) |
| Two-finger horizontal | Scroll sideways |
| Edge scroll | Same side as the holding hand, mirrored for left-handed use |

Control bar: `确认` = Enter (send / allow a permission prompt), `打断` = Esc (interrupt the
current generation), `胶囊` = hold to record an idea capsule, `删除` / `切换` send Backspace /
Cmd+Tab, plus a hold-to-talk key. Right-handed layout is `[voice][confirm][interrupt]`;
left-handed mirrors it.

Measured voice-path facts:

- the BLE link carries about **4 KB/s** (macOS settles on a 50–60 ms connection interval
  and one packet per event), so the wire format is 8 kHz / 40 ms / 160 B ADPCM at
  25 packets/s — just inside the budget, with no loss;
- capture uses `VOICE_COMMUNICATION` (system AGC + noise suppression);
  `VOICE_RECOGNITION` is attenuated to −43 dBFS on MIUI and is unusable;
- every session switches the system default input **before** pressing the trigger key
  (input methods grab the device at that instant) and then **rebuilds the AudioSink**,
  because changing the default input invalidates the old output binding — the engine
  keeps running with a live mixer level while the virtual device receives nothing.

Diagnostics: all voice events go to `~/Library/Logs/VibeDeck.log`, and the “声音路由” card
has “麦克风自检”, “回环自检 1kHz” and “录虚拟麦” buttons for checking each segment.

## Requirements

- Mac with Apple Silicon or Intel, macOS 13 or later.
- A Feixun T1/N1 original remote (HID + Kehwin service 1920).
- Pairing: hold **Home + Volume Down** together, then connect from System Settings → Bluetooth.

## Install

1. Download `FeiXunMai-0.3.0.pkg` from [Releases](../../releases/latest). It contains the app, the FeiXunV 2ch driver, and BlackHole 2ch.
2. The package is not notarized. Right-click it and choose **Open**; if macOS still blocks it, allow it under System Settings → Privacy & Security.
3. Grant Bluetooth permission.
4. In your voice app, set the microphone to **Automatic / Follow system default** (do not pin a specific device).
5. Hold the remote's voice key and talk. Grant Accessibility permission only if you use Fn emulation.

Build from source:

```zsh
./scripts/build-app.sh   # produces dist/VibeDeck.app, zip, dmg and the combined pkg
```

## How it works

```
voice key ─┬─ GATT 07fc01/07fc07 + mSBC stream → libsbc decode → 0.4 s gate (drops tap glitches)
           │                                      → drain buffer → FeiXunV/BlackHole virtual mic
           └─ HID F5 echo (swallowed in synthesized mode)
voice start ─┬─ synthesize Fn down (release +0.35 s after the buffer drains)
             └─ system default input → virtual mic; restore the real mic on release
other keys ─── HID report-layer "arm, then suppress": only the remote (VID 0x005D) is intercepted,
                identical key codes from a real keyboard always pass through
```

More design notes and measurements live in [docs/](docs/):
[key design](docs/按键设计.md) ·
[remote capabilities](docs/遥控器能力摸底.md) ·
[comparison](docs/对标梳理.md) ·
[lessons learned](docs/经验教训.md) ·
[HID verification plan](docs/HID验证计划.md)

## Known limitations

- While the voice key is held, Back/Home/Menu do not respond (the firmware pauses key reports during streaming; they recover on release).
- If the remote stops responding, pull the battery and reinsert it — a known RTL_618 firmware issue.
- Modifier triggers (⌘/⌥) can collide with app shortcuts; Fn is the safest default.

## Privacy

No network access, no uploads. Audio is decoded and routed locally; statistics stay in local UserDefaults.

## License and acknowledgements

- Project code: MIT — see [LICENSE](LICENSE).
- [BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential Audio: FeiXunV 2ch and BlackHole 2ch are modified builds of v0.7.1, licensed **GPL-3.0**. Modified source is in [driver/BlackHole-0.7.1](driver/BlackHole-0.7.1/).
- [google/libsbc](https://github.com/google/libsbc): mSBC decoding (Apache-2.0).

**Special thanks to [Wireless Mic SayAll (HD838A/remote-mic-app)](https://github.com/HD838A/remote-mic-app).** The product idea, the arm-then-suppress HID architecture, the "trigger follows the audio stream, not the key event" timing, the audio wiring order that fixed our silent virtual mic, and much of the debugging map came from its public documentation and its 343-entry bug archive. If this project helps you, give SayAll a star too.


## Building from source

macOS 13+ with Xcode Command Line Tools:

```bash
./scripts/build-app.sh
# outputs: dist/VibeDeck.app, dist/VibeDeck-0.5.0.zip / .dmg, dist/VibeDeckMCP
```

The Android app needs JDK 21 and the Android SDK:

```bash
cd vibepad
echo "sdk.dir=/path/to/Android/sdk" > local.properties
./gradlew assembleDebug
# output: app/build/outputs/apk/debug/app-debug.apk
```

## Idea Capsules (VibePad)

Hold the **Capsule** key on the phone, say a thought, release: the phone records a WAV locally.
When connected, it uploads over a dedicated Wi-Fi channel. Once the Mac has had about 8 seconds
without keyboard or mouse input, it transcribes automatically: switch the default input, rebuild
the virtual audio sink, hold the voice key, play the recording into FeiXunV, and let Doubao type
the text into a small HUD panel. The text is written back to the capsule and pushed to the phone.

If you touch the keyboard or mouse during transcription it aborts immediately, keeps the capsule
pending, and restores focus. The Mac's Capsules page is a sticky-note grid with manual transcription
and a folder shortcut. A read-only MCP server exposes the capsules to agents.
