# Промпт для сессии Claude Code на Mac: хост iPad Display для macOS

Скопируйте текст ниже целиком в новую сессию Claude Code на Mac (в любой папке).

---

Склонируй https://github.com/manar-mk/ipad-display в ~/ipad-display и работай там. Это личный проект (аккаунт GitHub manar-mk), коммить и пушить в main можно.

## Что это и что уже работает

iPad mini 1 (iOS 9.3.5, джейлбрейк, armv7) используется как второй монитор. На iPad стоит наше нативное приложение «iPad Display» (папка ios/, собирается в GitHub Actions, workflow ios-build; ставится по SSH командой `node tools/push-app.js out/IPadDisplay.app`, iPad должен быть разблокирован). Хост на Electron (main.js, panel.html, ffenc.js) на Windows работает полностью: H.264 60 fps, автообнаружение iPad по UDP-маячку (порт 7802) с приоритетом USB (usbmuxd), звук через виртуальный кабель, касания и жесты. Прочитай README.md и main.js целиком перед работой: протокол, настройки, приоритеты соединений и все особенности описаны там.

Задача: сделать так, чтобы тот же хост работал на этом Mac как на Windows: виртуальный монитор, 60 fps H.264, звук как отдельное устройство вывода, касания и жесты. Приложение на iPad НЕ трогать, протокол НЕ менять: iPad-сторона уже проверена и стабильна.

## Что нужно сделать на macOS (по порядку, каждый шаг проверять)

1. Запуск. `npm install && npm start`. При первом запуске macOS спросит «Запись экрана» для Electron — дать. Проверить, что панель открылась, что iPad находится по Wi-Fi (на iPad открыть «iPad Display»; хост должен показать «подключено по Wi-Fi»), и что картинка (пусть пока зеркало основного экрана) идёт. Кабель USB: usbmuxd в macOS встроен (/var/run/usbmuxd), usbmux.js его уже поддерживает. Диагностика: `node tools/device-info.js` (USB), `IPAD_SSH_HOST=<ip iPad> node tools/ssh.js "cat /tmp/ipaddisplay.log"` (журнал звука на iPad, там нет head/tail, только cat). Пароль root на iPad стандартный alpine, пользователь в курсе.

2. Виртуальный монитор 1024×768. Windows-вариант — драйвер в driver/windows и кнопка в панели (ipc install-vdd). Для macOS сделай driver/macos/vdisplay.swift: помощник на приватном API CGVirtualDisplay (как в открытом DeskPad, https://github.com/Stengo/DeskPad — посмотри их реализацию), который создаёт дисплей 1024×768 @ 60 Гц с именем «iPad Display» и держит его, пока процесс жив; компилируется через `swiftc` (Command Line Tools: `xcode-select --install`). Хост на darwin должен: собрать помощник при первом запуске, если бинарника нет; запускать его при старте захвата и убивать при выходе; выбирать этот дисплей автоматически (pickSource уже предпочитает второй экран 4:3). Кнопка «Установить виртуальный монитор» в панели на darwin должна запускать сборку/запуск помощника вместо PowerShell-скрипта. Если CGVirtualDisplay не заводится на этой версии macOS, запасной путь — попросить пользователя поставить DeskPad (`brew install --cask deskpad`) и описать это в панели.

3. Кодек. В main.js `encoderMode()` на darwin возвращает webcodecs (ffmpeg-ветка только для win32). Сначала проверь, даёт ли Electron на Mac аппаратный VideoToolbox через WebCodecs: в panel.html список конфигураций ENC_CONFIGS, в логе панели строки «encoder configured … prefer-hardware» или «Encoder creation error». Если аппаратный конфиг проходит — оставить WebCodecs. Если нет — добавить в ffenc.js ветку для darwin: захват `-f avfoundation -framerate 60 -capture_cursor 1 -i "<индекс экрана>:none"` (индекс экрана взять из `ffmpeg -f avfoundation -list_devices true -i ""`, сопоставить с выбранным дисплеем по размеру, как probeOutputs делает через ddagrab), кодер `-c:v h264_videotoolbox -realtime 1 -profile:v baseline -b:v 8M -g 120 -bf 0`, вывод `-f h264 pipe:1`; парсер AnnexBParser уже режет поток на кадры по AUD; убедись, что videotoolbox выдаёт AUD (иначе резать по первому слайсу: NAL типа 1/5 с first_mb_in_slice=0, это старший бит второго байта NAL). ffmpeg ставится `brew install ffmpeg`, findFfmpeg() научи искать /opt/homebrew/bin и /usr/local/bin. Целевые цифры: 60 fps в панели, задержка «сеть+декодер» 5–10 мс, на iPad без crash-логов (`ls /var/mobile/Library/Logs/CrashReporter/`).

4. Звук как отдельное устройство. Аналог VB-CABLE — BlackHole: `brew install blackhole-2ch`. В Audio MIDI Setup пользователь создаёт «Multi-Output Device» (BlackHole + встроенные динамики), чтобы звук шёл и на Mac, и на iPad; опиши это в README. Захват для приложения делается вторым ffmpeg в главном процессе (как AudioCapture в ffenc.js, там dshow), для darwin: `-f avfoundation -i ":BlackHole 2ch" -ac 1 -ar 22050 -f s16le pipe:1` (имя устройства взять из `-list_devices`). Регулярное выражение выбора устройства (isCable в panel.html и в main.js startExternalAudio) дополни словом BlackHole. Захват звука в окне панели (ScriptProcessor) на Windows замирал при свёрнутом окне — поэтому основной путь для приложения именно ffmpeg в главном процессе, не меняй это.

5. Касания и жесты. В main.js для darwin сейчас заглушка на python3+Quartz (pyobjc обычно нет). Замени на помощник driver/macos/mousehelper.swift: читает stdin построчно, команды те же, что у PowerShell-помощника в mouseCmd(): `move x y`, `down x y`, `up x y`, `rclick x y`, `wheel d`, `hwheel d`, `zoom d` (d кратен 120, знак важен). Реализация через CGEvent: движение/кнопки — CGEventCreateMouseEvent; колесо — CGEventCreateScrollWheelEvent с единицами kCGScrollEventUnitLine (d/120 строк, hwheel — вторая ось); zoom — то же колесо с флагом Command (kCGEventFlagMaskCommand), так масштабируют браузеры и большинство приложений на Mac. Координаты приходят в точках (в onTouch для darwin уже так), масштабный коэффициент не применять. Помощник компилируется swiftc при первом использовании. Нужно разрешение «Универсальный доступ» для Electron — при отказе показать в панели подсказку. Проверка как на Windows: `node tools/test-client.js ws://127.0.0.1:7800/ 3` шлёт touch в центр захватываемого экрана, положение курсора проверить через CGEvent.location в помощнике или Swift-однострочником.

6. README: раздел «macOS» с командами brew (ffmpeg, blackhole-2ch, при необходимости deskpad), разрешениями и порядком запуска; таблицу файлов дополни driver/macos/.

## Особенности, на которые уже наступали

- Не редактируй README и JS через `node -e` с обратными кавычками в bash: bash выполняет их как команды. Пользуйся Edit.
- iOS-приложение пересобирать не нужно. Если всё же придётся, сборка идёт в GitHub Actions, SDK там урезанный: нет strcmp/memset/memcpy для некоторых объектов, замены через Foundation. Установка: `gh run download -n IPadDisplay.app -D out`, unzip, `node tools/push-app.js out/IPadDisplay.app`.
- На Mac usbmuxd читает записи доверия из /var/db/lockdown (нужен sudo для tools/list-apps.js); сам туннель и SSH работают без этого.
- В настройках хоста (~/Library/Application Support/ipad-display/settings.json) codec должен быть auto.

Итог сессии: закоммитить и запушить, в конце коротко написать, что проверено на Mac, какие цифры fps/задержки получены, что не заработало.
