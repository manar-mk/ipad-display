# Приложение «iPad Display» на iPad: установка и запуск

Нативное приложение нужно для H.264 (60 fps), звука, жестов и работы по кабелю USB.
Если всё это не нужно — откройте хост в Safari по QR-коду, ставить ничего не придётся.

---

## Требования

- **iPad с джейлбрейком.** Проверено: iPad mini 1 (A1432), iOS 9.3.5, EverPwnage 2.0.1 с untether iocaste.
  Приложение подписывается на устройстве утилитой `ldid` и кладётся в `/Applications`, поэтому Apple ID,
  сертификаты и переустановка каждые 7 дней не нужны.
- **OpenSSH на iPad** (EverPwnage ставит его галочкой «Install OpenSSH»). Логин `root`, пароль по
  умолчанию `alpine` — смените его командой `passwd` в терминале на iPad; хосту пароль передаётся
  переменной `IPAD_SSH_PASS`.
- **Связь с iPad**: кабель USB (нужен usbmuxd, см. ниже) или Wi-Fi (`IPAD_SSH_HOST=<ip iPad>`).
- **usbmuxd на компьютере** для кабеля:
  - macOS — встроен;
  - Windows — приложение «Apple Devices» из Microsoft Store (`winget install 9NP83LWLPZ9K --source msstore`).
    Его нужно один раз запустить после подключения iPad: фоновый процесс AppleMobileDeviceProcess
    и есть usbmuxd (127.0.0.1:27015). Установка iTunes через winget usbmuxd не даёт — компонент
    Mobile Device Support не ставится; из полного установщика с сайта Apple ставится.
- **GitHub CLI** (`gh`), чтобы забрать собранное приложение из Actions.

Проверить, что iPad виден по кабелю:

```bash
node tools/usbmux-list.js
```

Ожидаемый ответ — серийный номер устройства. Строка «tunnel … failed: устройство отклонило соединение»
означает, что туннель работает, просто приложение ещё не запущено.

---

## Установка

Приложение собирается в GitHub Actions (`.github/workflows/ios-build.yml`) — Xcode не нужен:
на Linux-раннере работают clang и ld64 из тулчейна theos с SDK iPhoneOS 9.3.

```bash
# 1. взять последнюю успешную сборку
gh run download --repo manar-mk/ipad-display -n IPadDisplay.app -D out
cd out && unzip -o IPadDisplay.app.zip && cd ..

# 2. залить на iPad (по кабелю)
node tools/push-app.js out/IPadDisplay.app

#    или по Wi-Fi
IPAD_SSH_HOST=192.168.1.50 node tools/push-app.js out/IPadDisplay.app
```

Скрипт сам: копирует бандл в `/Applications/IPadDisplay.app`, ставит права, подписывает `ldid`,
обновляет иконки командой `uicache`, кладёт утилиту `sblaunch` и запускает приложение.
**iPad должен быть разблокирован** — заблокированный экран не даёт SpringBoard запускать приложения
(в выводе будет «launch failed (3): device locked»).

Собрать новую версию после правок в `ios/`:

```bash
git push                     # сборка стартует сама
gh run watch                 # дождаться зелёной галочки
```

---

## Запуск

- Иконка «iPad Display» на экране «Домой» (синий значок с планшетом).
- С компьютера: `node tools/ssh.js "sblaunch com.manar.ipaddisplay"` (iPad разблокирован).

На экране ожидания приложение показывает свой адрес, порт и выбранный компьютер. Дальше всё
происходит само: хост находит iPad и начинает передачу.

**Выбор компьютера.** Если хостов несколько, тапните тремя пальцами (или кнопку «Хост» на экране
ожидания) и выберите нужный. Выбор запоминается: по Wi-Fi другие компьютеры получат отказ, по кабелю
подключение принимается всегда — воткнутый кабель и есть явный выбор.

**После перезагрузки iPad** джейлбрейк не активен, и приложение не запустится: откройте EverPwnage,
нажмите Jailbreak, дождитесь перезапуска SpringBoard, затем откройте «iPad Display».

---

## Если что-то не так

| Симптом | Причина и решение |
|---|---|
| `launch failed (3): device locked` | Разблокируйте iPad и повторите |
| `iPad по USB не найден` | Запустите «Apple Devices» (Windows); проверьте кабель; `node tools/usbmux-list.js` |
| Приложение не появляется в списке | `node tools/list-apps.js Any` и `node tools/ssh.js "uicache"` |
| Приложение падает при запуске | `node tools/ssh.js "ls -t /var/mobile/Library/Logs/CrashReporter/ | grep -i ipaddisplay"`, затем `cat` нужного `.ips` |
| Нет звука | Журнал `node tools/ssh.js "cat /tmp/ipaddisplay.log"`: там статусы AudioQueue, формат и счётчик пакетов |
| Хост не видит iPad по Wi-Fi | Приложение открыто и не свёрнуто; одна сеть; в панели включено «подключаться автоматически» |
| iPad «занят» | В сети есть другой хост, который уже показывает на него картинку: выберите компьютер тапом тремя пальцами |

---

## Как приложение устроено

| Файл | Назначение |
|---|---|
| `ios/IPadDisplay/FrameServer.h/.m` | TCP-сервер на порту 7801, UDP-маячок, приём кадров и звука, отправка касаний |
| `ios/IPadDisplay/ViewController.m` | вывод H.264 через AVSampleBufferDisplayLayer, JPEG через UIImageView, AudioQueue, жесты, выбор хоста |
| `ios/IPadDisplay/Info.plist` | bundle id `com.manar.ipaddisplay`, иконки, полноэкранный режим, все ориентации |
| `ios/build.sh` | сборка без Xcode: clang + ld64, подстановка переменных в Info.plist, копирование иконок |
| `ios/tools/sblaunch.c` | запуск приложения по bundle id через приватный SpringBoardServices |

Особенности сборки, о которых стоит помнить при правках: SDK из репозитория theos урезан, в нём нет
заглушек для `strcmp`, `memset` и `memcpy` — используйте эквиваленты из Foundation; iOS-иконки должны
быть без альфа-канала (их рисует `node tools/make-icons.js`).
