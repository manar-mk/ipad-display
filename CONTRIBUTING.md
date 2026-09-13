# Contributing

Thanks for taking a look. This is a small personal project, so the process is short —
but `main` is protected and everything goes through a pull request.

*Русская версия — в конце файла.*

## Before you start

Open an issue first if the change is more than a fix: this project talks to a very specific pile of
hardware (a jailbroken iPad mini 1 on iOS 9.3.5, an IddCx virtual display on Windows, a
`CGVirtualDisplay` one on macOS), and a change that is right in the abstract can be impossible to
test here.

## Setting up

```bash
git clone https://github.com/manar-mk/ipad-display.git
cd ipad-display
npm run setup     # Node, ffmpeg, virtual cable, virtual display driver, icons, shortcut
npm start
```

`install.ps1` (Windows) and `install.sh` (macOS) are re-runnable: they skip whatever is already
installed. The iPad side is described in [docs/IPAD-APP.md](docs/IPAD-APP.md).

## While you work

* Run `npm test` before pushing — it parses every source file, checks the npm scripts point at real
  files, and proves the Russian and English dictionaries carry exactly the same keys. CI runs the
  same thing on your pull request.
* Any user-visible string goes through `i18n.js` in **both** languages (`t('some.key')` in the panel
  script, `data-i18n="some.key"` in markup). In the iOS app use `L(@"…", @"…")`.
* Match the surrounding code: no framework in the panel, plain DOM; comments explain *why*, not what.
* Keep commits focused, with a message that says what changed and why.

## Pull requests

1. Branch off `main` (`git switch -c fix-something`).
2. Push and open a PR; fill in the template.
3. CI (`checks`) has to be green and the owner has to approve — that is what the branch protection
   on `main` enforces.
4. Squash merge; the branch is deleted automatically.

## Reporting bugs

Use the issue templates. For anything about the connection, please attach:

* what the panel's status pill says,
* the host log (the terminal you started it from, or the Electron window's DevTools console),
* on the iPad: `node tools/ssh.js "cat /tmp/ipaddisplay.log"` (over USB) — it carries the audio and
  decoder trail.

---

# Как участвовать

Спасибо, что заглянули. Проект небольшой и личный, поэтому процесс короткий — но ветка `main`
защищена, и всё идёт через pull request.

## Перед началом

Если изменение больше, чем починка мелочи, сначала заведите issue: проект завязан на очень
конкретное железо (jailbroken iPad mini 1 на iOS 9.3.5, виртуальный дисплей IddCx на Windows и
`CGVirtualDisplay` на macOS), и правильное «в теории» изменение бывает невозможно здесь проверить.

## Как поднять у себя

```bash
git clone https://github.com/manar-mk/ipad-display.git
cd ipad-display
npm run setup     # Node, ffmpeg, виртуальный кабель, драйвер дисплея, иконки, ярлык
npm start
```

`install.ps1` (Windows) и `install.sh` (macOS) можно запускать повторно: уже установленное они
пропускают. Про приложение для iPad — [docs/IPAD-APP.md](docs/IPAD-APP.md).

## Во время работы

* Перед пушем запустите `npm test`: он проверяет синтаксис всех файлов, что npm-скрипты указывают на
  существующие файлы, и что русский и английский словари содержат одинаковый набор ключей. В CI
  выполняется ровно то же самое.
* Любая видимая пользователю строка добавляется в `i18n.js` **на обоих языках** (`t('some.key')` в
  скрипте панели, `data-i18n="some.key"` в разметке). В приложении для iOS — `L(@"…", @"…")`.
* Пишите в стиле окружающего кода: в панели нет фреймворков, только DOM; комментарии объясняют
  *почему*, а не что.
* Коммиты — по одному смыслу на коммит, с внятным сообщением.

## Pull request

1. Ветка от `main` (`git switch -c fix-something`).
2. Пуш, открываете PR, заполняете шаблон.
3. CI (`checks`) должен быть зелёным, и нужен аппрув владельца — это и требуют правила защиты `main`.
4. Мерж — squash; ветка удаляется автоматически.

## Баг-репорты

Пользуйтесь шаблонами. Для проблем с подключением приложите:

* что написано в статусной «пилюле» панели,
* лог хоста (терминал, из которого он запущен, или консоль DevTools окна Electron),
* с iPad: `node tools/ssh.js "cat /tmp/ipaddisplay.log"` (по USB) — там след звука и декодера.
