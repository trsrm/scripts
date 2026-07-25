#!/bin/zsh
set -euo pipefail

echo "=== VCMI Async через iCloud Drive ==="
echo
echo "Перед запуском:"
echo "1) У VCMI створи Hotseat-сейв з фіксованою назвою, наприклад ASYNC_GAME."
echo "2) У Finder створи спільну папку iCloud Drive і дай другому гравцеві право редагування."
echo "3) Обидва гравці мають використовувати однакову назву сейва."
echo

CONFIG_DIR="$HOME/Library/Application Support/VCMIAsync"
SCRIPT_PATH="$CONFIG_DIR/vcmi-async.zsh"
CONFIG_PATH="$CONFIG_DIR/config.zsh"
STATE_DIR="$CONFIG_DIR/state"
LOG_DIR="$CONFIG_DIR/logs"
PLIST_PATH="$HOME/Library/LaunchAgents/dev.romaniv.vcmi-async.plist"

mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"

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

echo "Вибери локальну папку VCMI Saves."
echo "Типовий шлях: ~/Library/Application Support/vcmi/Saves"
SAVE_DIR="$(choose_folder "Вибери папку VCMI Saves")"
SAVE_DIR="${SAVE_DIR%/}"

echo
echo "Вибери СПІЛЬНУ папку VCMI Async в iCloud Drive."
ICLOUD_DIR="$(choose_folder "Вибери спільну папку VCMI Async в iCloud Drive")"
ICLOUD_DIR="${ICLOUD_DIR%/}"

echo
read "SAVE_NAME?Назва сейва без розширення [ASYNC_GAME]: "
SAVE_NAME="${SAVE_NAME:-ASYNC_GAME}"

read "SELF_ID?Твій короткий ID латиницею, наприклад taras: "
SELF_ID="${SELF_ID:l}"
if [[ ! "$SELF_ID" =~ '^[a-z0-9_-]+$' ]]; then
  echo "ID може містити лише латинські літери, цифри, _ та -"
  exit 1
fi

read "SELF_NAME?Твоє ім'я для повідомлень [${SELF_ID}]: "
SELF_NAME="${SELF_NAME:-$SELF_ID}"

read "PEER_ID?ID другого гравця латиницею, наприклад andrii: "
PEER_ID="${PEER_ID:l}"
if [[ ! "$PEER_ID" =~ '^[a-z0-9_-]+$' ]]; then
  echo "ID може містити лише латинські літери, цифри, _ та -"
  exit 1
fi

read "PEER_NAME?Ім'я другого гравця [${PEER_ID}]: "
PEER_NAME="${PEER_NAME:-$PEER_ID}"

read "PEER_EMAIL?Email другого гравця (Enter — без email): "
PEER_EMAIL="${PEER_EMAIL:-}"

cat > "$CONFIG_PATH" <<EOF
SAVE_DIR=${(q)SAVE_DIR}
ICLOUD_DIR=${(q)ICLOUD_DIR}
SAVE_NAME=${(q)SAVE_NAME}
SELF_ID=${(q)SELF_ID}
SELF_NAME=${(q)SELF_NAME}
PEER_ID=${(q)PEER_ID}
PEER_NAME=${(q)PEER_NAME}
PEER_EMAIL=${(q)PEER_EMAIL}
EMAIL_ENABLED=true
POLL_SECONDS=10
STABILITY_SECONDS=6
EOF

cat > "$SCRIPT_PATH" <<'SCRIPT'
#!/bin/zsh
set -u

CONFIG_DIR="$HOME/Library/Application Support/VCMIAsync"
source "$CONFIG_DIR/config.zsh"

STATE_DIR="$CONFIG_DIR/state"
LOG_DIR="$CONFIG_DIR/logs"
mkdir -p "$STATE_DIR" "$LOG_DIR" "$ICLOUD_DIR"

LAST_LOCAL_FILE="$STATE_DIR/last-local-hash"
LAST_INCOMING_FILE="$STATE_DIR/last-incoming-archive-hash"
OUTGOING="$ICLOUD_DIR/to-${PEER_ID}.zip"
INCOMING="$ICLOUD_DIR/to-${SELF_ID}.zip"

log() {
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_DIR/agent.log"
}

notify_local() {
  /usr/bin/osascript - "$PEER_NAME" "$SAVE_NAME" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set peerName to item 1 of argv
  set saveName to item 2 of argv
  display notification "Сейв «" & saveName & "» уже завантажено. Можна відкривати VCMI." with title "Heroes 3 — твоя черга" subtitle peerName & " завершив хід"
end run
APPLESCRIPT
}

send_email() {
  [[ "$EMAIL_ENABLED" == "true" ]] || return 0
  [[ -n "$PEER_EMAIL" ]] || return 0

  /usr/bin/osascript - "$PEER_EMAIL" "$SELF_NAME" "$SAVE_NAME" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set recipientAddress to item 1 of argv
  set senderName to item 2 of argv
  set saveName to item 3 of argv

  tell application "Mail"
    set msg to make new outgoing message with properties {visible:false, subject:"Heroes 3 — твоя черга", content:senderName & " завершив хід у партії «" & saveName & "»." & return & return & "Сейв синхронізується через iCloud Drive. Відкрий VCMI та завантаж «" & saveName & "»." & return}
    tell msg
      make new to recipient at end of to recipients with properties {address:recipientAddress}
      send
    end tell
  end tell
end run
APPLESCRIPT
}

save_files() {
  /usr/bin/find "$SAVE_DIR" -maxdepth 1 -type f \( \
    -name "${SAVE_NAME}.vcgm1" -o \
    -name "${SAVE_NAME}.vsgm1" -o \
    -name "${SAVE_NAME}.vlgm1" -o \
    -name "${SAVE_NAME}" \
  \) -print | /usr/bin/sort
}

bundle_hash() {
  local files
  files="$(save_files)"
  [[ -n "$files" ]] || return 1

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    /usr/bin/shasum -a 256 "$file"
  done <<< "$files" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

package_and_send() {
  local staging tmpzip file
  staging="$(/usr/bin/mktemp -d "$STATE_DIR/outgoing.XXXXXX")" || return 1
  tmpzip="$(/usr/bin/mktemp "$STATE_DIR/outgoing.XXXXXX.zip")" || {
    /bin/rm -rf "$staging"
    return 1
  }

  while IFS= read -r file; do
    [[ -f "$file" ]] && /bin/cp -p "$file" "$staging/"
  done <<< "$(save_files)"

  if [[ -z "$(/usr/bin/find "$staging" -type f -maxdepth 1 -print -quit)" ]]; then
    log "Немає файлів сейва для відправлення"
    /bin/rm -rf "$staging" "$tmpzip"
    return 1
  fi

  /usr/bin/ditto -c -k --norsrc "$staging" "$tmpzip" || {
    log "Помилка створення ZIP"
    /bin/rm -rf "$staging" "$tmpzip"
    return 1
  }

  # Атомарна заміна в межах спільної iCloud-папки.
  /bin/cp "$tmpzip" "${OUTGOING}.new"
  /bin/mv -f "${OUTGOING}.new" "$OUTGOING"

  /bin/rm -rf "$staging" "$tmpzip"
  log "Сейв відправлено: $OUTGOING"

  # Даємо iCloud трохи часу почати завантаження, потім надсилаємо email.
  /bin/sleep 10
  send_email || log "Mail не зміг надіслати email"
}

import_incoming() {
  local archive_hash old_hash staging backup imported_hash
  [[ -f "$INCOMING" ]] || return 0

  archive_hash="$(/usr/bin/shasum -a 256 "$INCOMING" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 0
  [[ -n "$archive_hash" ]] || return 0
  old_hash="$(cat "$LAST_INCOMING_FILE" 2>/dev/null || true)"
  [[ "$archive_hash" != "$old_hash" ]] || return 0

  # Перевіряємо, що файл уже стабільний і повністю доступний локально.
  local size1 size2
  size1="$(/usr/bin/stat -f '%z' "$INCOMING" 2>/dev/null || echo 0)"
  /bin/sleep "$STABILITY_SECONDS"
  size2="$(/usr/bin/stat -f '%z' "$INCOMING" 2>/dev/null || echo 0)"
  [[ "$size1" == "$size2" && "$size2" -gt 0 ]] || return 0
  /usr/bin/unzip -tqq "$INCOMING" >/dev/null 2>&1 || return 0

  staging="$(/usr/bin/mktemp -d "$STATE_DIR/incoming.XXXXXX")" || return 1
  /usr/bin/ditto -x -k "$INCOMING" "$staging" || {
    log "Не вдалося розпакувати вхідний сейв"
    /bin/rm -rf "$staging"
    return 1
  }

  backup="$STATE_DIR/backup-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup"

  while IFS= read -r file; do
    [[ -f "$file" ]] && /bin/cp -p "$file" "$backup/"
  done <<< "$(save_files)"

  # Видаляємо лише файли цієї конкретної партії.
  /bin/rm -f \
    "$SAVE_DIR/${SAVE_NAME}.vcgm1" \
    "$SAVE_DIR/${SAVE_NAME}.vsgm1" \
    "$SAVE_DIR/${SAVE_NAME}.vlgm1" \
    "$SAVE_DIR/${SAVE_NAME}"

  /usr/bin/find "$staging" -maxdepth 1 -type f -exec /bin/cp -p {} "$SAVE_DIR/" \;
  /bin/rm -rf "$staging"

  print -r -- "$archive_hash" > "$LAST_INCOMING_FILE"
  imported_hash="$(bundle_hash 2>/dev/null || true)"
  [[ -n "$imported_hash" ]] && print -r -- "$imported_hash" > "$LAST_LOCAL_FILE"

  log "Вхідний сейв імпортовано"
  notify_local
}

main_loop() {
  log "Агент запущено. SAVE_DIR=$SAVE_DIR; ICLOUD_DIR=$ICLOUD_DIR"

  # Перший запуск: поточний локальний сейв стає базовим і не відправляється сам.
  if [[ ! -f "$LAST_LOCAL_FILE" ]]; then
    local initial_hash
    initial_hash="$(bundle_hash 2>/dev/null || true)"
    [[ -n "$initial_hash" ]] && print -r -- "$initial_hash" > "$LAST_LOCAL_FILE"
  fi

  while true; do
    import_incoming

    local current_hash previous_hash stable_hash
    current_hash="$(bundle_hash 2>/dev/null || true)"
    previous_hash="$(cat "$LAST_LOCAL_FILE" 2>/dev/null || true)"

    if [[ -n "$current_hash" && "$current_hash" != "$previous_hash" ]]; then
      /bin/sleep "$STABILITY_SECONDS"
      stable_hash="$(bundle_hash 2>/dev/null || true)"

      if [[ "$stable_hash" == "$current_hash" ]]; then
        if package_and_send; then
          print -r -- "$stable_hash" > "$LAST_LOCAL_FILE"
        fi
      fi
    fi

    /bin/sleep "$POLL_SECONDS"
  done
}

main_loop
SCRIPT

chmod 700 "$SCRIPT_PATH"

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

  <key>KeepAlive</key>
  <true/>

  <key>ProcessType</key>
  <string>Background</string>

  <key>StandardOutPath</key>
  <string>${LOG_DIR}/stdout.log</string>

  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/stderr.log</string>

  <key>ThrottleInterval</key>
  <integer>10</integer>
</dict>
</plist>
EOF

/bin/launchctl bootout "gui/$(id -u)/dev.romaniv.vcmi-async" 2>/dev/null || true
/bin/launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
/bin/launchctl enable "gui/$(id -u)/dev.romaniv.vcmi-async"
/bin/launchctl kickstart -k "gui/$(id -u)/dev.romaniv.vcmi-async"

echo
echo "Інсталяцію завершено."
echo "Конфіг: $CONFIG_PATH"
echo "Логи:   $LOG_DIR/agent.log"
echo
echo "ВАЖЛИВО:"
echo "- Перший наявний сейв вважається базовим і не відправляється."
echo "- Щоб зробити першу передачу, відкрий VCMI, завантаж сейв, збережи його ще раз і закрий гру."
echo "- Під час першої відправки macOS може попросити дозволити керування Mail. Натисни Allow."
echo
echo "Тестове системне повідомлення зараз з'явиться."
/usr/bin/osascript -e 'display notification "Фоновий агент установлено" with title "VCMI Async"'

if [[ -n "$PEER_EMAIL" ]]; then
  echo
  read "TEST_MAIL?Надіслати тестовий email другому гравцеві зараз? [y/N]: "
  if [[ "${TEST_MAIL:l}" == "y" ]]; then
    /usr/bin/osascript - "$PEER_EMAIL" "$SELF_NAME" <<'APPLESCRIPT'
on run argv
  set recipientAddress to item 1 of argv
  set senderName to item 2 of argv
  tell application "Mail"
    set msg to make new outgoing message with properties {visible:false, subject:"VCMI Async — тест", content:"Автоматизацію для " & senderName & " налаштовано. Це тестовий лист." & return}
    tell msg
      make new to recipient at end of to recipients with properties {address:recipientAddress}
      send
    end tell
  end tell
end run
APPLESCRIPT
  fi
fi

echo
echo "Готово."
