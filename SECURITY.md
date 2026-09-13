# Security policy

## Supported versions

Only the tip of `main` is maintained. There are no releases to back-port to.

## Reporting a vulnerability

Please **do not** open a public issue. Use
[GitHub's private vulnerability reporting](https://github.com/manar-mk/ipad-display/security/advisories/new)
for this repository. I usually answer within a few days.

## What this software actually does

Worth knowing before you deploy it anywhere but your own desk — the design assumes a trusted home
network:

* **The host listens on your LAN.** An HTTP + WebSocket server on port `7800` serves the Safari
  client, and it has **no authentication**: anyone who can reach that port sees your screen and can
  send touch events, which the host injects as real mouse input. Run it on a network you trust, or
  keep the Safari path off and use the native app over USB.
* **The iPad app listens on port `7801`** and answers a UDP beacon on `7802`. It accepts the first
  host that connects unless you pin one in the host picker; a pinned host applies to Wi-Fi only —
  a USB connection is always accepted, because the cable implies physical access.
* **Touch events become mouse and keyboard input** on the machine running the host. A malicious
  peer on either port can drive your computer.
* **`autolaunch` uses SSH to the iPad** with the jailbreak's default credentials (`root`/`alpine`,
  override with `IPAD_SSH_PASS`). It only ever runs over the USB tunnel. Change that password on any
  device that leaves your desk — with it, anyone on your network owns the iPad.
* **Nothing is encrypted.** Frames, audio and input travel as plain TCP.
* The host changes machine state while a session runs: it attaches a virtual monitor and unhides the
  virtual audio endpoints, and it puts them back on stop. None of it needs administrator rights;
  installing the drivers (a one-off, via `install.ps1`) does.

A jailbroken iOS 9 device is unsupported by Apple and has unpatched vulnerabilities. Please do not
use one for anything you care about — the iPad in this project is a screen and nothing else.
