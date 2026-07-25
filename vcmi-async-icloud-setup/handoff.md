Ось стислий контекст сесії для продовження:

## Що хоче користувач

Тарас із братом хочуть грати у **Heroes 3 через VCMI асинхронно**, як у шахи:

* один відкрив гру;
* зробив свій хід;
* зберіг;
* закрив;
* другий пізніше отримав повідомлення;
* відкрив той самий сейв;
* зробив свій хід.

У самому VCMI повноцінного async multiplayer немає, тому обрали workaround через **Hotseat-сейв**.

## Вимоги до рішення

Після одноразового налаштування UX має бути максимально автоматичний:

> прийшов email або notification → відкрив VCMI → завантажив `ASYNC_GAME` → походив → зберіг під тією самою назвою → закрив.

Користувач не хоче:

* Dropbox;
* S3;
* AWS CLI;
* ручного копіювання;
* перейменування файлів;
* запуску команд після кожного ходу.

Використовуємо лише те, що вже є в macOS:

* iCloud Drive;
* спільна папка Apple;
* shell;
* `launchd`;
* AppleScript;
* Mail.app;
* системні notifications.

## Обрана архітектура

На кожному Mac:

* VCMI працює зі своїм локальним сейвом;
* фоновий скрипт стежить за змінами `ASYNC_GAME`;
* після стабільного Save пакує всі файли сейва в ZIP;
* кладе ZIP у спільну папку iCloud:

  * `to-taras.zip`
  * `to-brother.zip`
* надсилає email іншому гравцеві через Mail.app;
* на Mac отримувача інший агент:

  * бачить новий ZIP;
  * перевіряє його;
  * робить backup локального сейва;
  * імпортує новий сейв;
  * показує notification.

Важливо: не один спільний сейв напряму в iCloud, а локальні сейви + iCloud як транспорт. Це зменшує ризик конфліктів.

## Готовий інсталятор

Було створено ZIP:

[VCMI Async iCloud Setup](sandbox:/mnt/data/VCMI-Async-iCloud-Setup.zip)

Усередині:

* `install-vcmi-async.command`
* `README.md`

Інсталятор:

* просить вибрати локальну папку VCMI Saves;
* просить вибрати спільну папку `VCMI Async` в iCloud Drive;
* питає:

  * назву сейва;
  * `SELF_ID`;
  * `SELF_NAME`;
  * `PEER_ID`;
  * `PEER_NAME`;
  * email другого гравця;
* створює:

  * конфіг;
  * універсальний shell-скрипт;
  * `launchd` plist;
  * state і logs;
* запускає агента;
* тестує notification;
* може надіслати тестовий email.

## Типова конфігурація

На Mac Тараса:

```text
SAVE_NAME=ASYNC_GAME
SELF_ID=taras
SELF_NAME=Тарас
PEER_ID=andrii
PEER_NAME=Андрій
PEER_EMAIL=...
```

На Mac брата:

```text
SAVE_NAME=ASYNC_GAME
SELF_ID=andrii
SELF_NAME=Андрій
PEER_ID=taras
PEER_NAME=Тарас
PEER_EMAIL=...
```

## Куди встановлюється

```text
~/Library/Application Support/VCMIAsync/
```

Усередині:

```text
config.zsh
vcmi-async.zsh
state/
logs/
```

LaunchAgent:

```text
~/Library/LaunchAgents/dev.romaniv.vcmi-async.plist
```

## Основні технічні деталі

Скрипт:

* polling раз на 10 секунд;
* чекає стабільності файлу;
* рахує SHA-256;
* дедуплікує повторні події;
* пакує всі можливі файли сейва:

  * `.vcgm1`
  * `.vsgm1`
  * `.vlgm1`
  * файл без розширення;
* атомарно замінює ZIP у iCloud;
* робить локальні backups;
* не відправляє отриманий сейв назад циклом;
* надсилає email через AppleScript і Mail.app;
* показує notification через `display notification`.

## Щоденний сценарій

1. Прийшов email.
2. Дочекатися notification, що сейв уже імпортовано.
3. Відкрити VCMI.
4. Завантажити `ASYNC_GAME`.
5. Зробити свій хід.
6. Зберегти під тією самою назвою.
7. Закрити VCMI.

## Ключові правила

* Не відкривати партію одночасно на двох Mac.
* Завжди зберігати під тією самою назвою.
* На обох Mac мають бути однакова версія VCMI, карта і моди.
* Не оновлювати VCMI або моди посеред партії.
* Після Save не присипляти Mac миттєво; дати приблизно 30 секунд на iCloud і Mail.

## Діагностика

Статус агента:

```bash
launchctl print "gui/$(id -u)/dev.romaniv.vcmi-async"
```

Перезапуск:

```bash
launchctl kickstart -k "gui/$(id -u)/dev.romaniv.vcmi-async"
```

Лог:

```bash
tail -50 "$HOME/Library/Application Support/VCMIAsync/logs/agent.log"
```

Помилки:

```bash
open "$HOME/Library/Application Support/VCMIAsync/logs/stderr.log"
```
