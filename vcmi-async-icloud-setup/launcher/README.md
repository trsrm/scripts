# Однокліковий запуск VCMI Async

## Звичайний запуск

Основний `install-vcmi-async.command` перевіряє готовий `.app` і встановлює його
в `~/Applications`. Після цього launcher доступний у списку програм macOS,
Spotlight і Dock.

Під час першого встановлення дозволь **Accessibility** для **Грати VCMI Async**.
Якщо macOS окремо попросить **Notifications** — також дозволь. Локально підписана
збірка не потребує Apple Developer certificate: якщо сучасний Notifications API
її не приймає, launcher автоматично використовує сумісне системне notification
з кнопкою **Грати хід**. Запустити партію можна зі списку програм або кліком по
notification **«Heroes 3 — твоя черга»**.

Якщо дозвіл уже ввімкнений, але launcher досі його не бачить, видали зі списку
старий запис **applet** кнопкою **−**, запусти встановлений `.app` з
`~/Applications` і дозволь **Грати VCMI Async**. Збірка 1.3 має стабільну локальну
designated requirement, тому наступні перекомпіляції не повинні скидати цей
дозвіл.

Застосунок запускає `vcmiclient` без VCMI Launcher і натискає послідовність Load Game → Multiplayer → Hotseat → підтвердження імен → останній сейв. Зараз VCMI зберігає останнім сейвом `async-game`.

Якщо VCMI вже працює, застосунок лише переводить її на передній план і не надсилає клавіші. Це захищає відкриту гру від випадкових натискань.

Готовий встановлений `.app` також можна запустити з Terminal:

```sh
open "$HOME/Applications/Грати VCMI Async.app"
```

## Повторне створення `.app`

Launcher написаний одним невеликим Swift-файлом і не збирає VCMI. Після редагування `vcmi-async-launcher.swift` виконай:

```sh
./build.zsh
```

Після переходу зі збірки 1.0 на 1.1 macOS попросить дозволити Accessibility ще раз. Наступні локальні збірки з тим самим bundle ID та executable зберігають ту саму designated requirement.

Перевірити дозвіл без запуску VCMI:

```sh
"./Грати VCMI Async.app/Contents/MacOS/vcmi-async-launcher" --check-accessibility
```

Встановити або оновити тільки готову копію launcher’а:

```sh
./install.zsh
```

Звичайний робочий шлях — запускати кореневий installer, який оновлює і sync-agent,
і launcher разом.

## Якщо автоматичні натискання випереджають меню

Збільш `mainMenuDelay` або `stepDelay` у `vcmi-async-launcher.swift`, а потім повторно створи `.app`.

Журнали:

- `/tmp/vcmi-async-launcher.log` — етапи автоматизації та помилки launcher;
- `/tmp/vcmi-async-launch.log` — stdout/stderr клієнта VCMI.
