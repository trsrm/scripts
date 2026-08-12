#!/bin/zsh
set -euo pipefail

echo "=== VCMI Async через iCloud Drive ==="
echo
echo "Перед запуском:"
echo "1) У VCMI створи Hotseat-сейв з фіксованою назвою, наприклад ASYNC_GAME."
echo "2) У Finder створи спільну папку iCloud Drive і дай другому гравцеві право редагування."
echo "3) Обидва гравці мають використовувати однакову назву сейва."
echo

INSTALLER_DIR="${0:A:h}"
AGENT_SOURCE="$INSTALLER_DIR/vcmi-async.zsh"
LAUNCHER_INSTALLER="$INSTALLER_DIR/launcher/install.zsh"
CONFIG_DIR="$HOME/Library/Application Support/VCMIAsync"
SCRIPT_PATH="$CONFIG_DIR/vcmi-async.zsh"
CONFIG_PATH="$CONFIG_DIR/config.zsh"
STATE_DIR="$CONFIG_DIR/state"
LOG_DIR="$CONFIG_DIR/logs"
PLIST_PATH="$HOME/Library/LaunchAgents/dev.romaniv.vcmi-async.plist"

mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"

if [[ ! -f "$AGENT_SOURCE" ]]; then
  echo "Не знайдено vcmi-async.zsh поруч з інсталятором"
  exit 1
fi
if ! /bin/zsh -n "$AGENT_SOURCE"; then
  echo "vcmi-async.zsh містить синтаксичну помилку"
  exit 1
fi
if [[ ! -f "$LAUNCHER_INSTALLER" ]] || ! /bin/zsh -n "$LAUNCHER_INSTALLER"; then
  echo "Не знайдено коректний launcher/install.zsh"
  exit 1
fi

choose_folder() {
  local prompt="$1"
  /usr/bin/osascript - "$prompt" <<'APPLESCRIPT'
on run argv
  set promptText to item 1 of argv
  set chosenFolder to choose folder with prompt promptText
  return POSIX path of chosenFolder
end run
APPLESCRIPT
}

prompt_default() {
  local label="$1" default="$2" value
  read "value?${label} [${default}]: "
  REPLY="${value:-$default}"
}

validate_inputs() {
  if [[ -z "$SAVE_NAME" || "$SAVE_NAME" == "." || "$SAVE_NAME" == ".." ||
    "$SAVE_NAME" == */* || "$SAVE_NAME" == *:* || "$SAVE_NAME" == *'\'* ||
    "$SAVE_NAME" == *'*'* || "$SAVE_NAME" == *'?'* ||
    "$SAVE_NAME" == *'['* || "$SAVE_NAME" == *']'* ||
    "$SAVE_NAME" == *$'\n'* || "$SAVE_NAME" == *$'\r'* ]]; then
    echo "Назва сейва не може містити / : \\ * ? [ ] або перенос рядка"
    return 1
  fi
  if [[ ! "$SELF_ID" =~ '^[a-z0-9_-]+$' || ! "$PEER_ID" =~ '^[a-z0-9_-]+$' ]]; then
    echo "ID може містити лише латинські літери, цифри, _ та -"
    return 1
  fi
  if [[ "$SELF_ID" == "$PEER_ID" ]]; then
    echo "Твій ID та ID другого гравця мають відрізнятися"
    return 1
  fi
  if [[ ! -d "$SAVE_DIR" || ! -d "$ICLOUD_DIR" ]]; then
    echo "Папки VCMI Saves та VCMI Async мають існувати"
    return 1
  fi
}

sync_identity_changed() {
  [[ "$SAVE_DIR" != "$OLD_SAVE_DIR" || "$ICLOUD_DIR" != "$OLD_ICLOUD_DIR" ||
    "$SAVE_NAME" != "$OLD_SAVE_NAME" || "$SELF_ID" != "$OLD_SELF_ID" ||
    "$PEER_ID" != "$OLD_PEER_ID" ]]
}

IS_UPDATE=false
RESET_SYNC_STATE=false
if [[ -f "$CONFIG_PATH" ]]; then
  IS_UPDATE=true
  source "$CONFIG_PATH"
  EMAIL_ENABLED="${EMAIL_ENABLED:-true}"
  OLD_SAVE_DIR="$SAVE_DIR"
  OLD_ICLOUD_DIR="$ICLOUD_DIR"
  OLD_SAVE_NAME="$SAVE_NAME"
  OLD_SELF_ID="$SELF_ID"
  OLD_PEER_ID="$PEER_ID"

  echo "Знайдено наявну конфігурацію. Натисни Enter, щоб залишити поточне значення."
  prompt_default "Папка VCMI Saves" "$SAVE_DIR"; SAVE_DIR="$REPLY"
  prompt_default "Спільна папка VCMI Async" "$ICLOUD_DIR"; ICLOUD_DIR="$REPLY"
  prompt_default "Назва сейва без розширення" "$SAVE_NAME"; SAVE_NAME="$REPLY"
  prompt_default "Твій короткий ID" "$SELF_ID"; SELF_ID="$REPLY"
  prompt_default "Твоє ім'я для повідомлень" "$SELF_NAME"; SELF_NAME="$REPLY"
  prompt_default "ID другого гравця" "$PEER_ID"; PEER_ID="$REPLY"
  prompt_default "Ім'я другого гравця" "$PEER_NAME"; PEER_NAME="$REPLY"
  prompt_default "Email другого гравця (- щоб вимкнути)" "$PEER_EMAIL"; PEER_EMAIL="$REPLY"
  [[ "$PEER_EMAIL" == "-" ]] && PEER_EMAIL=""
else
  echo "Вибери локальну папку VCMI Saves."
  echo "Типовий шлях: ~/Library/Application Support/vcmi/Saves"
  SAVE_DIR="$(choose_folder "Вибери папку VCMI Saves")"

  echo
  echo "Вибери СПІЛЬНУ папку VCMI Async в iCloud Drive."
  ICLOUD_DIR="$(choose_folder "Вибери спільну папку VCMI Async в iCloud Drive")"

  echo
  prompt_default "Назва сейва без розширення" "ASYNC_GAME"; SAVE_NAME="$REPLY"
  read "SELF_ID?Твій короткий ID латиницею, наприклад taras: "
  prompt_default "Твоє ім'я для повідомлень" "$SELF_ID"; SELF_NAME="$REPLY"
  read "PEER_ID?ID другого гравця латиницею, наприклад andrii: "
  prompt_default "Ім'я другого гравця" "$PEER_ID"; PEER_NAME="$REPLY"
  read "PEER_EMAIL?Email другого гравця (Enter — без email): "
  PEER_EMAIL="${PEER_EMAIL:-}"
  EMAIL_ENABLED=true
fi

SAVE_DIR="${SAVE_DIR%/}"
ICLOUD_DIR="${ICLOUD_DIR%/}"
SELF_ID="${SELF_ID:l}"
PEER_ID="${PEER_ID:l}"

validate_inputs || exit 1

if [[ "$IS_UPDATE" == "true" ]] && sync_identity_changed; then
  RESET_SYNC_STATE=true
fi

cat > "$CONFIG_PATH" <<EOF
SAVE_DIR=${(q)SAVE_DIR}
ICLOUD_DIR=${(q)ICLOUD_DIR}
SAVE_NAME=${(q)SAVE_NAME}
SELF_ID=${(q)SELF_ID}
SELF_NAME=${(q)SELF_NAME}
PEER_ID=${(q)PEER_ID}
PEER_NAME=${(q)PEER_NAME}
PEER_EMAIL=${(q)PEER_EMAIL}
EMAIL_ENABLED=${(q)EMAIL_ENABLED}
EOF
chmod 600 "$CONFIG_PATH"

/usr/bin/install -m 700 "$AGENT_SOURCE" "$SCRIPT_PATH"

echo
echo "Встановлюю launcher у список програм macOS."
INSTALLED_LAUNCHER="$(/bin/zsh "$LAUNCHER_INSTALLER")"
LAUNCHER_EXECUTABLE="$INSTALLED_LAUNCHER/Contents/MacOS/vcmi-async-launcher"
echo "Launcher: $INSTALLED_LAUNCHER"

if ! "$LAUNCHER_EXECUTABLE" --request-notifications; then
  echo "УВАГА: Notifications не дозволені. Увімкни їх для «Грати VCMI Async» у System Settings."
fi
"$LAUNCHER_EXECUTABLE" --request-accessibility >/dev/null 2>&1 || true

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.romaniv.vcmi-async</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>${SCRIPT_PATH}</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>StartInterval</key>
  <integer>60</integer>

  <key>ProcessType</key>
  <string>Background</string>

  <key>StandardOutPath</key>
  <string>${LOG_DIR}/stdout.log</string>

  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/stderr.log</string>

</dict>
</plist>
EOF
plutil -lint "$PLIST_PATH" >/dev/null

if [[ "$IS_UPDATE" == "false" || "$RESET_SYNC_STATE" == "true" ]]; then
  /bin/rm -f \
    "$STATE_DIR/last-local-hash" \
    "$STATE_DIR/last-incoming-archive-hash" \
    "$STATE_DIR/pending-local-hash"
  /bin/rm -rf "$STATE_DIR/incoming-cache" "$STATE_DIR/outgoing-cache"
  /bin/mkdir -p "$STATE_DIR/incoming-cache" "$STATE_DIR/outgoing-cache"
fi
/bin/rm -f "$STATE_DIR/last-incoming-name" "$STATE_DIR/alert-cleanup"
/bin/rm -f "$STATE_DIR/finder-automation-ok"
[[ "$IS_UPDATE" == "true" ]] || /bin/rm -f "$STATE_DIR/mail-automation-ok" "$STATE_DIR/send-test-email"

echo
echo "macOS може один раз попросити дозволити фоновому агенту керувати Finder."
echo "Натисни Allow — цей постійний дозвіл потрібен для обміну через iCloud."
/bin/launchctl bootout "gui/$(id -u)/dev.romaniv.vcmi-async" 2>/dev/null || true
/bin/launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
/bin/launchctl enable "gui/$(id -u)/dev.romaniv.vcmi-async"
/bin/launchctl kickstart -k "gui/$(id -u)/dev.romaniv.vcmi-async"

for _ in {1..35}; do
  [[ -f "$STATE_DIR/finder-automation-ok" ]] && break
  /bin/sleep 1
done
if [[ ! -f "$STATE_DIR/finder-automation-ok" ]]; then
  echo
  echo "ПОМИЛКА: доступ до Finder не підтверджено."
  echo "Дозволь Automation для Finder і запусти інсталятор ще раз."
  exit 1
fi

echo
echo "Інсталяцію завершено."
echo "Конфіг: $CONFIG_PATH"
echo "Логи:   $LOG_DIR/agent.log"
echo
echo "ВАЖЛИВО:"
echo "- Перший наявний сейв вважається базовим і не відправляється."
echo "- Щоб зробити першу передачу, відкрий VCMI, завантаж сейв, збережи його ще раз і закрий гру."
echo "- launchd запускає одну коротку перевірку приблизно раз на 60 секунд."
echo "- Новий локальний сейв має бути однаковим під час двох перевірок, тому передача займає 1–2 хвилини."
echo
echo "Тестове системне повідомлення зараз з'явиться."
/usr/bin/osascript -e 'display notification "Фоновий агент установлено" with title "VCMI Async"'

if [[ "$IS_UPDATE" == "false" && -n "$PEER_EMAIL" ]]; then
  echo
  echo "macOS може один раз попросити дозволити фоновому агенту керувати Mail."
  echo "Натисни Allow. Надалі агент не перевірятиме дозвіл перед кожним листом."
  for _ in {1..35}; do
    [[ -f "$STATE_DIR/mail-automation-ok" ]] && break
    /bin/sleep 1
  done

  if [[ -f "$STATE_DIR/mail-automation-ok" ]]; then
    echo "Доступ до Mail підтверджено."
    read "TEST_MAIL?Надіслати тестовий email другому гравцеві зараз? [y/N]: "
    if [[ "${TEST_MAIL:l}" == "y" ]]; then
      /usr/bin/touch "$STATE_DIR/send-test-email"
      /bin/launchctl kickstart -k "gui/$(id -u)/dev.romaniv.vcmi-async"
      echo "Запит передано фоновому агенту."
    fi
  else
    echo "Доступ до Mail не підтверджено. Email поки вимкнено, але iCloud-синхронізація працює."
    echo "Щоб спробувати ще раз, перезапусти агент і натисни Allow."
  fi
fi

echo
echo "Готово."
