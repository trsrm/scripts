# VCMI Async через iCloud Drive

Асинхронна Hotseat-партія між двома Mac:

1. дочекайся notification;
2. відкрий VCMI та завантаж `ASYNC_GAME`;
3. зроби хід;
4. збережи під тією самою назвою;
5. закрий VCMI.

`launchd` раз на хвилину запускає коротку перевірку. Скрипт приймає хід другого
гравця або публікує твій, а потім завершується.

## Як це працює

У спільній iCloud-папці завжди є максимум два транспортні файли:

```text
to-taras.zip
to-vitalii.zip
```

Кожен новий хід замінює попередній ZIP. SHA-256 визначає, чи змінився його
вміст. Перед імпортом агент перевіряє ZIP, створює локальний backup і лише тоді
замінює сейв VCMI.

Новий локальний сейв має мати однаковий хеш під час двох послідовних перевірок.
Тому від Save до публікації минає приблизно 1–2 хвилини. Вхідний хід зазвичай
імпортується протягом наступної хвилини.

## Встановлення

На обох Mac мають бути однакові VCMI, карта, моди й назва сейва. Один гравець
створює спільну папку `VCMI Async` в iCloud Drive та дає другому право
редагування.

Тримай ці файли разом:

- `install-vcmi-async.command`
- `vcmi-async.zsh`
- `README.md`

Запусти:

```bash
./install-vcmi-async.command
```

Вибери локальну папку VCMI Saves і спільну iCloud-папку. Типова папка сейвів:

```text
~/Library/Application Support/vcmi/Saves
```

Один раз натисни `Allow` для Finder і, якщо потрібен email, для Mail.

## Оновлення

Обидва гравці повинні встановити цю версію перед наступним ходом, бо вона
використовує новий стабільний формат імен ZIP.

Після `git pull` брат запускає в папці репозиторію:

```bash
./install-vcmi-async.command
```

Інсталятор підставить наявні дані. Enter залишає значення без змін. Зміна папки,
назви сейва або ID скидає лише sync-state; конфігурація і backups зберігаються.

## Повідомлення і помилки

Агент показує notification, коли:

- отриманий сейв уже встановлено;
- твій хід опубліковано;
- `SELF_ID` не відповідає адресованому гравцеві ZIP у спільній папці;
- Finder, Mail, ZIP або імпорт не працюють;
- робота після помилки відновилася.

Одна й та сама помилка показується один раз. Невдала операція автоматично
повторюється під час наступного запуску. Помилка email не блокує iCloud.

## Діагностика

```bash
tail -50 "$HOME/Library/Application Support/VCMIAsync/logs/agent.log"
open "$HOME/Library/Application Support/VCMIAsync/logs/stderr.log"
launchctl print "gui/$(id -u)/dev.romaniv.vcmi-async"
launchctl kickstart -k "gui/$(id -u)/dev.romaniv.vcmi-async"
```

Перевірка коду:

```bash
./tests/run.zsh
zsh -n vcmi-async.zsh
zsh -n install-vcmi-async.command
```

## Правила

- Не відкривайте партію одночасно на двох Mac.
- Завжди зберігайте під тією самою назвою.
- Перед відкриттям VCMI дочекайтеся notification про імпорт.
- Не оновлюйте VCMI або моди посеред партії.
- Після Save не присипляйте Mac приблизно дві хвилини.

## Видалення

```bash
launchctl bootout "gui/$(id -u)/dev.romaniv.vcmi-async"
rm -f "$HOME/Library/LaunchAgents/dev.romaniv.vcmi-async.plist"
rm -rf "$HOME/Library/Application Support/VCMIAsync"
```
