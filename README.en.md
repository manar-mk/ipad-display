# iPad Display — an old iPad as a second monitor for Windows and macOS

[![ci](https://github.com/manar-mk/ipad-display/actions/workflows/ci.yml/badge.svg)](https://github.com/manar-mk/ipad-display/actions/workflows/ci.yml)
[![build](https://github.com/manar-mk/ipad-display/actions/workflows/build.yml/badge.svg)](https://github.com/manar-mk/ipad-display/actions/workflows/build.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**English** · [Русский](README.md)

Turns an iPad into an extra screen for your computer: hardware H.264 at up to 60 fps, system sound,
and cursor control through touches and gestures. It works on the devices Sidecar, Duet and Luna
turned down — down to an iPad mini 1 / iPad 2 on iOS 9.3.5.

![The host panel](assets/screenshot.png)

- **A second monitor, not a mirror**: the host creates a 1024×768 virtual display, and windows you
  drag onto it show up on the iPad.
- **Two ways onto the iPad**: the native app (H.264, sound, gestures, works over the cable) or plain
  Safari with nothing to install.
- **It connects by itself**: the iPad announces itself on the network and the host finds it; a cable
  plugged in is picked up automatically as the faster, steadier link.
- **Nothing left behind**: on Stop the virtual monitor is detached, the audio device disappears from
  the system, and your windows come back to the main screen.

---

## Requirements

| What | Minimum | Tested on |
|---|---|---|
| Computer | Windows 10/11 or macOS 12+, Node.js 18+ | Windows 11 + RTX 3070 Ti, macOS 26.5 (M4 Pro) |
| iPad | anything with Safari and WebSocket (iOS 6+) | iPad mini 1 (A1432), iOS 9.3.5 |
| For the native app | a jailbreak + OpenSSH on the iPad | EverPwnage 2.0.1 + iocaste, iOS 9.3.5 |
| For the USB cable | usbmuxd on the computer | "Apple Devices" from the Microsoft Store / built into macOS |
| Hardware codec | ffmpeg | 9.0.1 (Windows), 8.1 (macOS) |
| Sound as its own device | VB-CABLE (Windows) or BlackHole (macOS) | both |

Network: the iPad and the computer on the same Wi-Fi. Over the cable no network is needed.

---

## Ready-made builds

Every push to `main` builds three artifacts in GitHub Actions (workflow `build`), and a `v*` tag
publishes them on the **[Releases](https://github.com/manar-mk/ipad-display/releases)** page:

| File | What it is |
|---|---|
| `iPad Display-<version>-setup-win-x64.exe` | Windows installer (NSIS); `…-portable-win-x64.exe` is the same host with no installation, just run it |
| `iPad Display-<version>-mac-arm64.dmg` / `-mac-x64.dmg` (and `.zip`) | the macOS app for Apple Silicon / Intel |
| `IPadDisplay-iPad-app.zip` | the iPad app (armv7, iOS 9); installed as described in [docs/IPAD-APP.en.md](docs/IPAD-APP.en.md) |

The builds are unsigned: on Windows SmartScreen say "More info → Run anyway"; on macOS right-click the
app → "Open" (or `xattr -d com.apple.quarantine "/Applications/iPad Display.app"`). The host still
needs ffmpeg (and on Windows "Apple Devices" for the cable, on macOS BlackHole for sound) — the
commands are below. To build locally: `npm install && npm run dist` (on macOS run `npm run helpers:mac`
first).

## One-click setup

```bash
git clone https://github.com/manar-mk/ipad-display
cd ipad-display
npm run setup
```

`install.ps1` (Windows, also runnable as `install.cmd`) and `install.sh` (macOS) install Node.js,
ffmpeg, the virtual audio cable, the virtual display driver, generate the icons and create the
desktop shortcut. They print in Russian or English depending on the system language and are safe to
re-run: anything already installed is skipped. Flags: `-NoDriver`, `-NoAudio`, `-Start`
(`--no-audio`, `--start` on macOS).

## Installing from source, step by step

### 1. The host on Windows

```bash
git clone https://github.com/manar-mk/ipad-display
cd ipad-display
npm install
winget install Gyan.FFmpeg                     # hardware H.264 through Media Foundation
winget install 9NP83LWLPZ9K --source msstore   # "Apple Devices": gives you usbmuxd for the cable
```

Also:

- **The virtual monitor** — the "Install the 1024×768 virtual monitor" button in the panel's first
  card (the [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver), MIT,
  lives in `driver/windows/`). Windows will ask for administrator confirmation.
- **Sound as its own device** — install [VB-CABLE](https://vb-audio.com/Cable/). A "CABLE Input"
  output appears in the system: everything routed to it goes to the iPad.
- **A desktop shortcut** is created with:

```bash
node tools/make-shortcut.js
```

### 2. The host on macOS

```bash
git clone https://github.com/manar-mk/ipad-display
cd ipad-display
npm install
xcode-select --install        # swiftc for the driver/macos helpers (they build themselves)
brew install ffmpeg           # avfoundation capture + hardware H.264 through VideoToolbox
brew install blackhole-2ch    # the virtual audio device (asks for an administrator password)
```

Permissions in System Settings → Privacy & Security (the panel tells you what is missing):
**Screen Recording** (restart the host after granting it), **Accessibility** (touches as mouse
input), **Microphone** (reading BlackHole). The macOS host creates the virtual monitor itself on
start.

### 3. The iPad

With nothing installed — **Safari**: start the host and scan the QR code from the "Without the app"
card. The picture is JPEG at 10–15 fps; sound starts on a tap.

The full experience — the **native app** (H.264 60 fps, sound, gestures, USB): see the separate
guide, **[docs/IPAD-APP.en.md](docs/IPAD-APP.en.md)**.

---

## Running it

1. Open **iPad Display** on the computer (the desktop shortcut or `npm start`).
2. Open **iPad Display** on the iPad.
3. Streaming starts by itself: "start capture on launch" is on by default, so the button already
   reads **Stop** and the pill in the header says "iPad connected over Wi-Fi" or "over USB". The
   Start button only appears when capture is stopped or the checkbox is cleared.
4. Drag the windows you want onto the new monitor (on Windows it shows up in Settings → System →
   Display, where you also place it relative to the main screen; on macOS in System Settings →
   Displays).
5. **Stop** ends the stream and removes the iPad's audio devices from the system. On Windows the
   virtual monitor is detached too; on macOS it lives as long as the host is open and disappears
   when you quit it.

The "How to use it" button in the panel header opens the same instructions, plus the usual problems
and their fixes, right inside the app. The language selector next to it switches the whole panel
between Russian and English (it follows the system language by default).

### Controlling the computer from the iPad

| Gesture | What it does |
|---|---|
| One finger | mouse: tap to click, move to drag |
| Two fingers | scroll (vertical and horizontal) |
| Pinch | zoom (Ctrl+wheel, ⌘+wheel on macOS) |
| Long press | right mouse button |
| Three-finger tap | pick the computer when there is more than one |

### Sound

System sound reaches the iPad as PCM, 22050 Hz, mono.

On **macOS** the "Make the iPad an audio device" button creates two output devices and selects the
first one right away:

| Device | Where the sound plays |
|---|---|
| **iPad Display** | on the iPad only — the Mac stays quiet, like plugging in a monitor with speakers |
| **iPad Display + speakers** | on the iPad and the Mac's speakers at the same time |

Switch between them in System Settings → Sound → Output, and take the sound back to the Mac in the
same place. To remove both: `driver/macos/audiosetup --remove`.

On **Windows** VB-CABLE plays that role: the "CABLE Input" output. To send just one application to
the iPad, assign it that device (Settings → System → Sound → Volume mixer; on macOS, in the
application's own settings). The cable device only exists while the stream is running.

The host can also switch the system default output (the "make it the default device" checkbox), but
utilities like Nahimic and Realtek Audio Console put their own choice back within seconds — which is
why the checkbox is off by default.

---

## What the host does by default

- Picks the virtual monitor (the second, 4:3 screen); on macOS it creates it first.
- Starts capturing as soon as it launches, with sound and touch input on.
- Listens for the iPad app's UDP beacons (port 7802) and connects by itself; the cable takes priority
  over Wi-Fi.
- When the cable is in but the app is not listening, it asks the iPad to open the app over SSH
  (setting `autolaunch`). If the iPad is locked, SpringBoard refuses and the panel says so.
- On Stop and on closing the window it removes the cable's audio devices; the virtual monitor is
  detached on Windows and disappears when you quit the host on macOS.

Settings: `%APPDATA%\ipad-display\settings.json`; on macOS `~/Library/Application Support/iPad Display/`
for the built app and `~/Library/Application Support/ipad-display/` when run from source.

---

## Troubleshooting

| Problem | What to check |
|---|---|
| The iPad is not found | The app is open on the iPad; both devices on the same network; "connect automatically" is ticked (the header pill warns you when it is not) |
| No sound on the iPad | The app is assigned the "CABLE Input" output; the "sound on the iPad" checkbox; the iPad's volume; the log `node tools/ssh.js "cat /tmp/ipaddisplay.log"` |
| The picture stutters | Plug the USB cable in, lower the bitrate; on Wi-Fi, 5 GHz helps |
| No virtual monitor | The install button in the panel's first card; on macOS, the CGVirtualDisplay error message and the DeskPad fallback |
| The app is gone from the iPad | After a reboot the jailbreak is not active: run EverPwnage → Jailbreak, then "iPad Display" |
| The iPad shows a different computer | Three-finger tap on the iPad → pick the host you want, or "Any host" |
| Black screen on the iPad, the app is running, port 7801 refused | `mediaserverd` on the device is wedged: `node tools/ssh.js "killall mediaserverd"`, then launch the app again |
| Sound plays on the computer but not on the iPad | Walk the path section by section — see "Why there is no sound" below |
| Several copies of the host are running | The first one holds port 7800, the rest quietly serve nobody. Check with `lsof -i :7800` (Windows: `netstat -ano \| findstr 7800`) |
| The iPad receives sound but stays silent | The on-device self test, see "Why there is no sound" below |
| Black screen on the iPad, everything else fine | The virtual monitor is empty — drag a window onto it. The tell-tale sign: 60 fps at ~0.1 Mbit/s |

Useful commands:

```bash
node tools/device-info.js                       # the iPad over USB: model, iOS, open ports
node tools/usbmux-list.js                       # usbmuxd and the tunnel to the iPad
node tools/list-apps.js Any                     # which apps are installed on the iPad
node tools/ssh.js "cat /tmp/ipaddisplay.log"    # the app's audio log (over Wi-Fi: IPAD_SSH_HOST=<ip>)
node tools/test-client.js ws://127.0.0.1:7800/ 3 # frames over WebSocket + a test touch
node tools/ssh.js "touch /tmp/ipaddisplay.selftest"  # a 440 Hz tone on the iPad; only sounds while the host is streaming (clear it with rm -f)
node tools/ssh.js "killall mediaserverd"             # restart the iPad's audio daemon
npm test                                        # sources, npm scripts and both translations
```

Commands with `tools/` are run from the project folder.

### Why there is no sound

The sound crosses four sections, and each is checked separately. Go in order: the first one that does
not match is the cause.

1. **Sound reaches the virtual cable.** It only does if the source application outputs to the cable
   device — "iPad Display" (or "iPad Display + speakers") on macOS, "CABLE Input" on Windows. If
   "iPad Display" is selected on macOS and you still hear the Mac's speakers, the source is going
   somewhere else: check the device chosen inside that application.
2. **The host reads the cable.** Every five seconds the host prints a line like
   `[panel] audio: … peak=A/B via ffmpeg`. It goes to the host's console, not to its window, so start
   the host from a terminal to see it:

   ```bash
   "dist/mac-arm64/iPad Display.app/Contents/MacOS/iPad Display"   # the built app
   npm start                                                        # from source
   ```

   `A` is the level the host sends to the iPad, `B` the level of the same cable as measured by the
   panel window. Both run from 0 to 32767. The table below holds for `via ffmpeg`: only there are `A`
   and `B` taken by two independent captures. With `via renderer` both numbers come from the same
   capture and cannot disagree.

   | Reading | What it means |
   |---|---|
   | `peak=0/0` | nothing is reaching the cable — back to step 1 |
   | `peak=0/large` | the host's capture is stuck; on macOS it restarts itself after about 8 seconds and prints `capturing silence` (Windows has no such watchdog — restart the host) |
   | both large | sound is going to the iPad, the cause is further along |

3. **The sound reaches the app on the iPad.** `node tools/ssh.js "cat /tmp/ipaddisplay.log"`: an
   `audio chunk #N` line is written for the first packet and then every 200th, so roughly every 19
   seconds, with the counter going 1 → 200 → 400. If it grows, packets are arriving. Later lines
   should say `started=1`; the very first one says `started=0`, which is expected — the queue has not
   been started yet.
4. **The iPad plays it.** `node tools/ssh.js "touch /tmp/ipaddisplay.selftest"` — the app only looks
   for that file while it is receiving sound from the host (about every 2 seconds), so the host has
   to be connected and streaming. The app then plays one second of a 440 Hz tone generated on the
   device itself and writes a `queue clock` line to the log. Its `sampleTime` field should grow by
   about the sample rate every second: if it stands still, nothing is being played. The tone repeats
   while the flag file is there; remove it with
   `node tools/ssh.js "rm -f /tmp/ipaddisplay.selftest"`.

   If you hear no tone, restart the device's audio daemon and the app:

   ```bash
   node tools/ssh.js "killall mediaserverd"
   node tools/ssh.js "sblaunch com.manar.ipaddisplay"
   ```

---

## How it works

```
┌──────────────── computer (Electron) ─────────────────┐        ┌──────── iPad ────────┐
│ virtual monitor  → ffmpeg (hardware H.264)           │ Wi-Fi  │ IPadDisplay.app      │
│                  → TCP 7801 ─────────────────────────┼───────►│ AVSampleBufferLayer  │
│ virtual audio cable → ffmpeg → PCM 22050 ────────────┼─ USB ─►│ AudioQueue           │
│ HTTP + WebSocket 7800 (JPEG for Safari) ◄────────────┼────────┤ touches, gestures    │
└──────────────────────────────────────────────────────┘        └──────────────────────┘
```

The protocol to the app: `[uint32 length][type][payload]`. From the host — `H` (avcC), `V` (an H.264
frame), `J` (JPEG), `F`/`A` (audio format and data), `N` (the host's name). From the iPad — a frame
ack, `T` (touch), `S` (scroll), `Z` (zoom), `R` (right click), `K` (send a keyframe), `P` (frame
shown — the latency figure comes from this), `X` (another host was chosen).

Discovery: every 2 s the iPad sends a UDP "IPADDISPLAY 7801" (plus "busy" when it is taken), and
hosts answer with their name — that is what the list of computers on the iPad is built from.

**Codecs.** H.264 is the main path: Media Foundation (Windows) or VideoToolbox (macOS) encode in
hardware, the iPad decodes in hardware; 60 fps at 1024×768, 2–8 Mbit/s, network+decoder latency
5–9 ms. JPEG is for Safari (iOS 9 has no Media Source Extensions) and as a fallback, 10–15 fps.

**Bluetooth is deliberately unsupported:** third-party apps on iOS only get BLE (tens of KB/s), and a
picture needs 1–2 MB/s.

---

## Layout

| File | Purpose |
|---|---|
| `main.js` | Electron main: HTTP/WebSocket 7800, the client to the app (USB/TCP), discovery, touches, session cleanup |
| `panel.html`, `preload.js` | the host window: capture, JPEG, WebCodecs, settings, instructions |
| `i18n.js` | the panel's text in both languages |
| `applaunch.js` | opening the app on the iPad over SSH when it does not answer on its port |
| `ffenc.js` | external hardware H.264 and audio capture through ffmpeg, Annex B parsing |
| `usbmux.js` | a usbmuxd client: the device list and a tunnel to a port on the iPad without iproxy |
| `client/index.html` | the web client for Safari (ES5, works on iOS 9) |
| `ios/` | the native app (Objective-C, iOS 9) + `build.sh` + `tools/sblaunch.c` |
| `driver/windows/` | Virtual Display Driver, `install-vdd.ps1`, `session.ps1` (the monitor and sound per session) |
| `driver/macos/` | `vdisplay.swift` (the virtual monitor), `mousehelper.swift` (mouse and gestures), `audiosetup.swift` (audio output devices), `build.sh` — the host compiles them with `swiftc` itself, and the built app ships them ready |
| `tools/` | installing onto the iPad, SSH, diagnostics, the icon generator, test clients, `check.js` |
| `assets/` | the app icons (`node tools/make-icons.js` draws them with no graphics editor) |
| `docs/IPAD-APP.en.md` | installing the app on the iPad |

Environment variables: `IPAD_DISPLAY_PORT` (the HTTP port, 7800), `IPAD_DISPLAY_AUTOSTART=1`,
`IPAD_DISPLAY_TCP=host:port` or `=usb`, `IPAD_DISPLAY_FFMPEG=<path>`, `IPAD_SSH_HOST`, `IPAD_SSH_PASS`.

---

## Limitations

- The iPad mini 1 is not Retina: anything above 1024×768 only adds traffic.
- Sound is uncompressed (~350 kbit/s) with 0.2–0.5 s of latency; HDCP-protected content is not
  captured.
- The jailbreak profile is lost when the iPad reboots — the app has to be started after jailbreaking
  again (see [docs/IPAD-APP.en.md](docs/IPAD-APP.en.md)).
- The native app only builds for armv7/iOS 9 (Xcode 14+ cannot target it, which is why the build runs
  in GitHub Actions on the theos Linux toolchain).

---

## Contributing, licence, security

* [CONTRIBUTING.md](CONTRIBUTING.md) — how to set up, what `npm test` checks, how pull requests work.
  `main` is protected: a review is required and CI has to be green.
* [SECURITY.md](SECURITY.md) — how to report a vulnerability, and what the open ports can do.
* [LICENSE](LICENSE) — MIT. Third-party components: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
