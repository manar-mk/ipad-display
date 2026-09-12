#!/usr/bin/env bash
# iPad Display — установщик для macOS / setup for macOS.
# Ставит зависимости через Homebrew и готовит проект. Повторный запуск безопасен.
# Installs the dependencies with Homebrew and prepares the project. Safe to re-run.
#
#   bash install.sh [--no-audio] [--start]
set -u
cd "$(dirname "$0")"

RU=0; case "${LANG:-}" in ru*|RU*) RU=1 ;; esac
say()  { if [ $RU = 1 ]; then echo "$1"; else echo "$2"; fi; }
step() { echo; if [ $RU = 1 ]; then echo "== $1"; else echo "== $2"; fi; }
ok()   { if [ $RU = 1 ]; then echo "   [ok] $1"; else echo "   [ok] $2"; fi; }
warn() { if [ $RU = 1 ]; then echo "   [!] $1"; else echo "   [!] $2"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

NO_AUDIO=0; START=0
for a in "$@"; do case "$a" in --no-audio) NO_AUDIO=1 ;; --start) START=1 ;; esac; done

echo
say "iPad Display — установка" "iPad Display — setup"
say "папка: $PWD" "folder: $PWD"

step "Command Line Tools (swiftc для помощников)" "Command Line Tools (swiftc for the helpers)"
if xcode-select -p >/dev/null 2>&1; then ok "уже есть" "already here"
else warn "открылось окно установки — дождитесь его окончания" "an installer window opened — let it finish"; xcode-select --install || true; fi

step "Homebrew" "Homebrew"
if have brew; then ok "уже есть" "already here"
else
  warn "ставлю Homebrew (спросит пароль)" "installing Homebrew (it will ask for your password)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || exit 1
  for p in /opt/homebrew/bin /usr/local/bin; do [ -x "$p/brew" ] && eval "$($p/brew shellenv)"; done
fi

step "Node.js" "Node.js"
if have node; then ok "уже есть: $(node -v)" "already here: $(node -v)"
else brew install node && ok "установлен $(node -v)" "installed $(node -v)"; fi

step "Зависимости проекта (npm install)" "Project dependencies (npm install)"
npm install --no-audit --no-fund >/dev/null && ok "готово" "done"

step "ffmpeg (аппаратный H.264 VideoToolbox, захват звука)" "ffmpeg (hardware H.264 via VideoToolbox, audio capture)"
if have ffmpeg || [ -x /opt/homebrew/bin/ffmpeg ] || [ -x /usr/local/bin/ffmpeg ]; then ok "уже есть" "already here"
else brew install ffmpeg && ok "установлен" "installed"; fi

if [ $NO_AUDIO = 0 ]; then
  step "Виртуальное аудиоустройство BlackHole" "Virtual audio device (BlackHole)"
  if system_profiler SPAudioDataType 2>/dev/null | grep -qi blackhole; then ok "уже есть" "already here"
  else
    warn "установка попросит пароль администратора" "the install will ask for an administrator password"
    brew install blackhole-2ch && ok "установлен" "installed"
  fi
fi

step "Иконки" "Icons"
node tools/make-icons.js >/dev/null && ok "нарисованы" "generated"

echo
say "── Готово ──" "── Done ──"
say "Запуск: npm start (или откройте проект и нажмите Старт)." "Run: npm start (then press Start in the panel)."
say "При первом запуске macOS попросит разрешения: Запись экрана, Универсальный доступ, Микрофон." \
   "On the first run macOS will ask for Screen Recording, Accessibility and Microphone permissions."
say "Приложение для iPad: docs/IPAD-APP.md" "The iPad app: docs/IPAD-APP.md"

[ $START = 1 ] && npm start
exit 0
