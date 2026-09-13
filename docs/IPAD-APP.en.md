# The "iPad Display" app on the iPad: installing and running it

**English** · [Русский](IPAD-APP.md)

The native app is what gives you H.264 (60 fps), sound, gestures and the USB cable. If you need none
of that, open the host in Safari from the QR code and install nothing.

---

## Requirements

- **A jailbroken iPad.** Tested on an iPad mini 1 (A1432), iOS 9.3.5, EverPwnage 2.0.1 with the
  iocaste untether. The app is signed on the device with `ldid` and placed in `/Applications`, so no
  Apple ID, no certificates and no reinstalling every 7 days.
- **OpenSSH on the iPad** (EverPwnage installs it with the "Install OpenSSH" checkbox). Login `root`,
  default password `alpine` — change it with `passwd` in a terminal on the iPad; the host takes the
  password from the `IPAD_SSH_PASS` variable.
- **A link to the iPad**: the USB cable (needs usbmuxd, see below) or Wi-Fi (`IPAD_SSH_HOST=<iPad ip>`).
- **usbmuxd on the computer** for the cable:
  - macOS — built in;
  - Windows — the "Apple Devices" app from the Microsoft Store
    (`winget install 9NP83LWLPZ9K --source msstore`). Run it once after plugging the iPad in: its
    background AppleMobileDeviceProcess *is* usbmuxd (127.0.0.1:27015). Installing iTunes through
    winget does **not** give you usbmuxd — the Mobile Device Support component is not installed; the
    full installer from Apple's site does install it.
- **GitHub CLI** (`gh`) to fetch the built app from Actions.

Check that the iPad is visible over the cable:

```bash
node tools/usbmux-list.js
```

The expected answer is the device's serial number. A line saying "tunnel … failed: connection
refused" means the tunnel works and the app simply is not running yet.

---

## Installing

The app is built in GitHub Actions (`.github/workflows/build.yml`, job `ipad-app`) — no Xcode needed:
clang and ld64 from the theos toolchain run on a Linux runner with the iPhoneOS 9.3 SDK. The finished
archive is on [Releases](https://github.com/manar-mk/ipad-display/releases) as
`IPadDisplay-iPad-app.zip` (the same `IPadDisplay.app.zip` as the workflow artifact).

```bash
# 1. take the latest successful build (or download IPadDisplay-iPad-app.zip from Releases into out/)
gh run download --repo manar-mk/ipad-display -n IPadDisplay.app -D out
cd out && unzip -o IPadDisplay.app.zip && cd ..

# 2. push it to the iPad (over the cable)
node tools/push-app.js out/IPadDisplay.app

#    or over Wi-Fi
IPAD_SSH_HOST=192.168.1.50 node tools/push-app.js out/IPadDisplay.app
```

The script copies the bundle to `/Applications/IPadDisplay.app`, fixes the permissions, signs it with
`ldid`, refreshes the icons with `uicache`, drops the `sblaunch` helper in place and launches the
app. **The iPad has to be unlocked** — a locked screen keeps SpringBoard from launching anything
(you will see `launch failed (3): device locked`, or `launch failed (11): timeout` when it gives up
waiting).

To build a new version after editing `ios/`:

```bash
git push                     # the build starts by itself
gh run watch                 # wait for the green tick
```

---

## Running it

- The "iPad Display" icon on the home screen (the blue tablet).
- From the computer: `node tools/ssh.js "sblaunch com.manar.ipaddisplay"` (with the iPad unlocked).

On its waiting screen the app shows its address, its port and the computer it is pinned to. After
that everything happens on its own: the host finds the iPad and starts streaming. The app speaks
Russian or English, following the iPad's own language.

The app keeps running in the background (`UIBackgroundModes: audio` plus a silent keep-alive stream),
so going to the home screen or locking the iPad no longer drops the connection.

**Choosing the computer.** With several hosts around, tap with three fingers (or the "Host" button on
the waiting screen) and pick one. The choice is remembered: other computers are turned away over
Wi-Fi, while a connection over the cable is always accepted — plugging a cable in *is* an explicit
choice.

**After the iPad reboots** the jailbreak is not active and the app will not start: open EverPwnage,
press Jailbreak, wait for SpringBoard to restart, then open "iPad Display".

---

## When something is wrong

| Symptom | Cause and fix |
|---|---|
| `launch failed (3): device locked` | Unlock the iPad and try again |
| `launch failed (11): timeout` | SpringBoard could not hand the app a scene — usually a locked screen, or a stuck instance: `node tools/ssh.js "killall IPadDisplay"` and launch again |
| Black screen, the process is alive, port 7801 refused | `mediaserverd` is wedged, and audio calls into it never return: `node tools/ssh.js "killall mediaserverd"`, then launch the app again |
| `iPad over USB not found` | Start "Apple Devices" (Windows); check the cable; `node tools/usbmux-list.js` |
| The app does not show up in the list | `node tools/list-apps.js Any` and `node tools/ssh.js "uicache"` |
| The app crashes on launch | `node tools/ssh.js "ls -t /var/mobile/Library/Logs/CrashReporter/ \| grep -i ipaddisplay"`, then `cat` the `.ips` you want |
| No sound | The log `node tools/ssh.js "cat /tmp/ipaddisplay.log"`: AudioQueue statuses, the format and the packet counter are all there |
| The host does not see the iPad over Wi-Fi | The app is open and not swiped away; same network; "connect automatically" is on in the panel |
| The iPad is "busy" | Another host on the network is already showing a picture on it: pick your computer with a three-finger tap |

---

## How the app is put together

| File | Purpose |
|---|---|
| `ios/IPadDisplay/FrameServer.h/.m` | the TCP server on port 7801, the UDP beacon, receiving frames and audio, sending touches |
| `ios/IPadDisplay/ViewController.m` | H.264 through AVSampleBufferDisplayLayer, JPEG through UIImageView, AudioQueue, gestures, the host picker |
| `ios/IPadDisplay/Info.plist` | bundle id `com.manar.ipaddisplay`, icons, full screen, every orientation, background audio |
| `ios/build.sh` | building without Xcode: clang + ld64, substituting the Info.plist variables, copying the icons |
| `ios/tools/sblaunch.c` | launching an app by bundle id through the private SpringBoardServices |

Two things about the build worth remembering when you edit it: the SDK from the theos repository is
stripped and has no stubs for `strcmp`, `memset` and `memcpy` — use the Foundation equivalents; and
iOS icons must have no alpha channel (`node tools/make-icons.js` draws them that way).

Anything that talks to `mediaserverd` — `AVAudioSession`, every `AudioQueue` call — must stay off the
main thread. Those are synchronous IPC calls, and a wedged daemon would otherwise freeze
`viewDidLoad` until SpringBoard kills the app for "failed to scene-create".
