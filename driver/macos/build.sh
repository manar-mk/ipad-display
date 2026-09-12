#!/usr/bin/env bash
# Builds the macOS helpers (vdisplay, mousehelper, audiosetup) with swiftc — the host does the same on first use;
# CI runs this before packaging so the .app ships them prebuilt. Same flags as macHelper() in main.js.
set -e
cd "$(dirname "$0")"
SWIFTC="xcrun swiftc -O"
$SWIFTC -import-objc-header CGVirtualDisplay.h vdisplay.swift -o vdisplay -framework CoreGraphics
$SWIFTC mousehelper.swift -o mousehelper -framework ApplicationServices
$SWIFTC audiosetup.swift -o audiosetup -framework CoreAudio
ls -la vdisplay mousehelper audiosetup
