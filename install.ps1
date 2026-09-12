# iPad Display — установщик для Windows / setup for Windows.
# Ставит всё, что нужно хосту, и создаёт ярлык. Запускать повторно безопасно: уже установленное пропускается.
# Installs everything the host needs and creates a desktop shortcut. Safe to re-run: existing parts are skipped.
#
#   двойной клик по install.cmd    |    double-click install.cmd
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-NoDriver] [-NoAudio] [-Start]
param(
  [switch]$AdminPhase,   # internal: the elevated half (drivers)
  [switch]$NoDriver,     # skip the virtual display driver
  [switch]$NoAudio,      # skip VB-CABLE
  [switch]$Start         # launch the host when done
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$RU = (Get-Culture).TwoLetterISOLanguageName -eq 'ru'
function Say($ru, $en) { Write-Host ($(if ($RU) { $ru } else { $en })) }
function Step($ru, $en) { Write-Host ""; Write-Host ("== " + $(if ($RU) { $ru } else { $en })) -ForegroundColor Cyan }
function Ok($ru, $en) { Write-Host ("   [ok] " + $(if ($RU) { $ru } else { $en })) -ForegroundColor Green }
function Warn($ru, $en) { Write-Host ("   [!] " + $(if ($RU) { $ru } else { $en })) -ForegroundColor Yellow }
function IsAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function RefreshPath { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }
function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function FindFfmpeg {
  if (Have 'ffmpeg') { return (Get-Command ffmpeg).Source }
  $p = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($p) { return $p.FullName }
  return $null
}
function HasCable { [bool](Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Class -eq 'MEDIA' -and $_.FriendlyName -match 'VB-Audio|CABLE' }) }
function HasVdd { [bool](Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Virtual Display Driver|VDD by MTT' }) }

# ---------------------------------------------------------------- elevated half
if ($AdminPhase) {
  if (-not $NoAudio -and -not (HasCable)) {
    Step 'Виртуальный аудиокабель VB-CABLE' 'Virtual audio cable (VB-CABLE)'
    $tmp = Join-Path $env:TEMP 'ipad-display-vbcable'
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $zip = Join-Path $tmp 'vbcable.zip'
    Invoke-WebRequest 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip' -OutFile $zip
    Expand-Archive $zip -DestinationPath $tmp -Force
    $setup = Join-Path $tmp 'VBCABLE_Setup_x64.exe'
    $p = Start-Process $setup -ArgumentList '-i', '-h' -WorkingDirectory $tmp -PassThru -Wait
    if (HasCable) { Ok 'VB-CABLE установлен' 'VB-CABLE installed' } else { Warn "установщик вернул $($p.ExitCode)" "setup returned $($p.ExitCode)" }
  }
  if (-not $NoDriver -and -not (HasVdd)) {
    Step 'Драйвер виртуального монитора' 'Virtual display driver'
    & (Join-Path $root 'driver\windows\install-vdd.ps1')
    if (HasVdd) { Ok 'монитор 1024x768 добавлен' 'the 1024x768 monitor was added' } else { Warn 'драйвер не встал' 'driver did not install' }
  }
  exit 0
}

# ---------------------------------------------------------------- user half
Write-Host ""
Say 'iPad Display — установка' 'iPad Display — setup'
Say "папка: $root" "folder: $root"

if (-not (Have 'winget')) {
  Warn 'Нет winget (Установщик приложений из Microsoft Store) — поставьте Node.js и ffmpeg вручную' `
       'winget is missing (App Installer from Microsoft Store) — install Node.js and ffmpeg manually'
}

Step 'Node.js' 'Node.js'
if (Have 'node') { Ok "уже есть: $(node -v)" "already here: $(node -v)" }
elseif (Have 'winget') {
  winget install --id OpenJS.NodeJS.LTS --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
  RefreshPath
  if (Have 'node') { Ok "установлен $(node -v)" "installed $(node -v)" } else { Warn 'перезапустите окно и повторите' 'reopen the terminal and re-run' ; exit 1 }
} else { Warn 'нужен Node.js 18+: https://nodejs.org' 'Node.js 18+ required: https://nodejs.org'; exit 1 }

Step 'Зависимости проекта (npm install)' 'Project dependencies (npm install)'
Push-Location $root
try { & npm install --no-audit --no-fund | Out-Null; Ok 'готово' 'done' } finally { Pop-Location }

Step 'ffmpeg (аппаратный H.264 и захват звука)' 'ffmpeg (hardware H.264 and audio capture)'
if (FindFfmpeg) { Ok "уже есть: $(FindFfmpeg)" "already here: $(FindFfmpeg)" }
elseif (Have 'winget') {
  winget install --id Gyan.FFmpeg --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
  RefreshPath
  if (FindFfmpeg) { Ok 'установлен' 'installed' } else { Warn 'не нашёлся — хост переключится на программный кодек' 'not found — the host will fall back to the software encoder' }
}

Step 'Поддержка кабеля USB (usbmuxd)' 'USB cable support (usbmuxd)'
if (Get-AppxPackage -Name 'AppleInc.AppleDevices' -ErrorAction SilentlyContinue) { Ok 'приложение «Apple Devices» установлено' 'the Apple Devices app is installed' }
elseif (Get-Service 'Apple Mobile Device Service' -ErrorAction SilentlyContinue) { Ok 'служба Apple Mobile Device работает' 'Apple Mobile Device Service is present' }
elseif (Have 'winget') {
  winget install --id 9NP83LWLPZ9K --source msstore --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
  if (Get-AppxPackage -Name 'AppleInc.AppleDevices' -ErrorAction SilentlyContinue) {
    Ok 'установлено — запустите его один раз после подключения iPad' 'installed — launch it once after plugging the iPad in'
  } else { Warn 'не установилось; кабель можно настроить позже' 'not installed; the cable can be set up later' }
}

Step 'Иконки и ярлык' 'Icons and shortcut'
& node (Join-Path $root 'tools\make-icons.js') | Out-Null
Ok 'иконки нарисованы' 'icons generated'
& node (Join-Path $root 'tools\make-shortcut.js')

$needAdmin = (-not $NoAudio -and -not (HasCable)) -or (-not $NoDriver -and -not (HasVdd))
if ($needAdmin) {
  Step 'Драйверы (нужен один запрос администратора)' 'Drivers (one administrator prompt)'
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path, '-AdminPhase')
  if ($NoDriver) { $args += '-NoDriver' }
  if ($NoAudio) { $args += '-NoAudio' }
  if (IsAdmin) { & powershell @args }
  else { Start-Process powershell -ArgumentList $args -Verb RunAs -Wait }
} else {
  Step 'Драйверы' 'Drivers'
  Ok 'виртуальный монитор и аудиокабель уже установлены' 'virtual monitor and audio cable are already installed'
}

Write-Host ""
Say '── Готово ──' '── Done ──'
if (HasVdd) { Ok 'виртуальный монитор' 'virtual monitor' } else { Warn 'виртуального монитора нет: кнопка установки есть в панели' 'no virtual monitor: there is an install button in the panel' }
if (HasCable) { Ok 'аудиокабель (звук на iPad)' 'audio cable (sound to the iPad)' } else { Warn 'аудиокабеля нет: звук пойдёт только как весь системный' 'no audio cable: only whole-system sound will be available' }
Say 'Дальше: откройте ярлык «iPad Display» и приложение на iPad, затем нажмите Старт.' `
    'Next: open the "iPad Display" shortcut and the iPad app, then press Start.'
Say 'Приложение для iPad: docs/IPAD-APP.md' 'The iPad app: docs/IPAD-APP.md'

if ($Start) { Start-Process (Join-Path $root 'node_modules\electron\dist\electron.exe') -ArgumentList $root -WorkingDirectory $root }
