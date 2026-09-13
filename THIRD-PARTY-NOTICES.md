# Third-party notices

iPad Display itself is MIT-licensed (see [LICENSE](LICENSE)). It ships or depends on the
components below, each under its own licence.

## Bundled in this repository

### Virtual Display Driver (`driver/windows/VirtualDisplayDriver/`)

`MttVDD.dll`, `MttVDD.inf`, `mttvdd.cat`, `vdd_settings.xml` — the IddCx virtual monitor driver
used to create the screen the iPad shows.

* Upstream: <https://github.com/VirtualDrivers/Virtual-Display-Driver>
* Licence: MIT
* Copyright (c) MikeTheTech and the Virtual-Display-Driver contributors

The MIT terms reproduced in [LICENSE](LICENSE) apply to these files as well, with the copyright
held by the upstream authors. Only the driver payload is redistributed here; installation is done
by `driver/windows/install-vdd.ps1`.

### `driver/macos/CGVirtualDisplay.h`

Header for Apple's private `CoreGraphics` virtual display API, reconstructed from the public class
dump at <https://github.com/JohnCoates/CGVirtualDisplay>. Apple's frameworks themselves are not
redistributed.

## Installed by the setup scripts, not redistributed

`install.ps1` / `install.sh` download and run vendor installers. None of these are part of this
repository and each keeps its own licence and terms:

| Component | Used for | Licence |
| --- | --- | --- |
| [Node.js](https://nodejs.org) | runtime of the host app | MIT |
| [FFmpeg](https://ffmpeg.org) (Gyan builds on Windows, Homebrew on macOS) | hardware H.264 encoding, audio capture | LGPL‑2.1+/GPL‑2+ depending on the build |
| [VB‑CABLE](https://vb-audio.com/Cable/) (Windows) | virtual audio device | free for personal use, donationware — see the vendor's licence |
| [BlackHole](https://github.com/ExistentialAudio/BlackHole) (macOS) | virtual audio device | MIT |
| [Apple Devices](https://apps.microsoft.com/detail/9np83lwlpz9k) / iTunes (Windows) | `usbmuxd` service for the USB link | Apple's EULA |

## npm dependencies

Runtime dependencies (`ws`, `qrcode`, `ssh2`) and the build dependency `electron` are fetched from
the npm registry and are MIT-licensed. `npm ls --all` and each package's own `LICENSE` file are the
authoritative source.

## iOS app

Built with the [theos](https://github.com/theos/theos) toolchain (MIT) against Apple's iOS 9.3 SDK.
The SDK is not redistributed here; CI fetches it at build time.
