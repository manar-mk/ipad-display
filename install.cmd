@echo off
rem iPad Display - one-click setup for Windows / установка в один клик.
rem Double-click this file. It installs Node.js, ffmpeg, usbmuxd, the virtual monitor driver
rem and the audio cable, then creates a desktop shortcut.
title iPad Display - setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
