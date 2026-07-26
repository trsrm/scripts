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

prompt_default() {
  local label="$1" default="$2" value
  read "value?${label} [${default}]: "
  REPLY="${value:-$default}"
}

IS_UPDATE=false
if [[ -f "$CONFIG_PATH" ]]; then
  IS_UPDATE=true
  source "$CONFIG_PATH"
  EMAIL_ENABLED="${EMAIL_ENABLED:-true}"
  CLEANUP_ENABLED="${CLEANUP_ENABLED:-true}"
  CLEANUP_KEEP="${CLEANUP_KEEP:-3}"
  POLL_SECONDS="${POLL_SECONDS:-10}"
  STABILITY_SECONDS="${STABILITY_SECONDS:-6}"

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
  prompt_default "Кількість збережених вихідних ZIP" "$CLEANUP_KEEP"; CLEANUP_KEEP="$REPLY"
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
  CLEANUP_ENABLED=true
  CLEANUP_KEEP=3
  POLL_SECONDS=10
  STABILITY_SECONDS=6
fi

SAVE_DIR="${SAVE_DIR%/}"
ICLOUD_DIR="${ICLOUD_DIR%/}"
SELF_ID="${SELF_ID:l}"
PEER_ID="${PEER_ID:l}"

if [[ ! "$SELF_ID" =~ '^[a-z0-9_-]+$' || ! "$PEER_ID" =~ '^[a-z0-9_-]+$' ]]; then
  echo "ID може містити лише латинські літери, цифри, _ та -"
  exit 1
fi
if [[ ! "$CLEANUP_KEEP" =~ '^[1-9][0-9]*$' ]]; then
  echo "Кількість збережених ZIP має бути додатним числом"
  exit 1
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
CLEANUP_ENABLED=${(q)CLEANUP_ENABLED}
CLEANUP_KEEP=${(q)CLEANUP_KEEP}
POLL_SECONDS=${(q)POLL_SECONDS}
STABILITY_SECONDS=${(q)STABILITY_SECONDS}
EOF

cat > "$SCRIPT_PATH" <<'SCRIPT'
#!/bin/zsh
set -u

CONFIG_DIR="$HOME/Library/Application Support/VCMIAsync"
source "$CONFIG_DIR/config.zsh"
CLEANUP_ENABLED="${CLEANUP_ENABLED:-true}"
CLEANUP_KEEP="${CLEANUP_KEEP:-3}"
[[ "$CLEANUP_KEEP" =~ '^[1-9][0-9]*$' ]] || CLEANUP_KEEP=3

STATE_DIR="$CONFIG_DIR/state"
LOG_DIR="$CONFIG_DIR/logs"
mkdir -p "$STATE_DIR" "$LOG_DIR" "$ICLOUD_DIR"

LAST_LOCAL_FILE="$STATE_DIR/last-local-hash"
LAST_INCOMING_FILE="$STATE_DIR/last-incoming-archive-hash"
LAST_SEEN_INCOMING_SIGNATURE=""
MAIL_AUTH_FILE="$STATE_DIR/mail-automation-ok"
MAIL_TEST_REQUEST="$STATE_DIR/send-test-email"
MAIL_READY=false

log() {
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_DIR/agent.log"
}

notify_user() {
  /usr/bin/osascript - "$1" "$2" "$3" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv)
end run
APPLESCRIPT
}

raise_alert() {
  local key="$1" subtitle="$2" message="$3"
  local marker="$STATE_DIR/alert-$key"
  [[ -f "$marker" ]] && return 0

  notify_user "VCMI Async — проблема" "$subtitle" "$message"
  /usr/bin/touch "$marker"
  log "ALERT[$key]: $subtitle — $message"
}

resolve_alerts() {
  local subtitle="$1" message="$2" key recovered=false
  shift 2

  for key in "$@"; do
    if [[ -f "$STATE_DIR/alert-$key" ]]; then
      /bin/rm -f "$STATE_DIR/alert-$key"
      recovered=true
    fi
  done

  if [[ "$recovered" == "true" && -n "$message" ]]; then
    notify_user "VCMI Async — відновлено" "$subtitle" "$message"
    log "RECOVERED: $subtitle — $message"
  fi
}

rotate_log() {
  local file="$1" size i
  [[ -f "$file" ]] || return 0
  size="$(/usr/bin/stat -f '%z' "$file" 2>/dev/null)" || return 0
  (( size < 1048576 )) && return 0

  /bin/rm -f "$file.3"
  for i in 2 1; do
    [[ -f "$file.$i" ]] && /bin/mv -f "$file.$i" "$file.$((i + 1))"
  done
  /bin/cp -p "$file" "$file.1" && : > "$file"
}

housekeeping() {
  local file candidate modified now i
  local -a backups

  for file in agent.log stdout.log stderr.log; do
    rotate_log "$LOG_DIR/$file"
  done

  backups=("$STATE_DIR"/backup-*(/omN))
  for (( i = 21; i <= ${#backups}; ++i )); do
    /bin/rm -rf "$backups[$i]"
  done

  now="$(/bin/date '+%s')"
  for candidate in "$STATE_DIR"/incoming.*(N) "$STATE_DIR"/outgoing.*(N) "$SAVE_DIR"/.vcmi-async.*(N); do
    modified="$(/usr/bin/stat -f '%m' "$candidate" 2>/dev/null)" || continue
    (( now - modified > 86400 )) && /bin/rm -rf "$candidate"
  done
}

notify_local() {
  notify_user \
    "Heroes 3 — твоя черга" \
    "$PEER_NAME завершив хід" \
    "Сейв «$SAVE_NAME» уже завантажено. Можна відкривати VCMI."
}

cleanup_outgoing() {
  [[ "$CLEANUP_ENABLED" == "true" ]] || return 0

  local i file failed=false
  local -a archives obsolete
  archives=("$ICLOUD_DIR"/to-${PEER_ID}-*.zip(.omN))
  (( ${#archives} > CLEANUP_KEEP )) || return 0

  for (( i = CLEANUP_KEEP + 1; i <= ${#archives}; ++i )); do
    obsolete+=("$archives[$i]")
  done

  /usr/bin/osascript -l JavaScript - "${obsolete[@]}" <<'JXA' >/dev/null 2>&1 || true
ObjC.import("Foundation");

function run(argv) {
  argv.forEach(path => {
    const url = $.NSURL.fileURLWithPath(path);
    const coordinator = $.NSFileCoordinator.alloc.initWithFilePresenter(undefined);
    const coordinationError = Ref();

    coordinator.coordinateWritingItemAtURLOptionsErrorByAccessor(
      url,
      1,
      coordinationError,
      coordinatedURL => {
        const deletionError = Ref();
        $.NSFileManager.defaultManager.removeItemAtURLError(coordinatedURL, deletionError);
      }
    );
  });
}
JXA

  for file in "${obsolete[@]}"; do
    [[ -e "$file" ]] && failed=true
  done

  if [[ "$failed" == "false" ]]; then
    log "Очищено старих вихідних ZIP: ${#obsolete}"
    resolve_alerts "Автоочищення знову працює" "Старі транспортні ZIP знову видаляються." cleanup
  else
    log "Не вдалося координовано видалити старі вихідні ZIP"
    raise_alert cleanup "Старі ZIP не очищаються" "Передача сейвів працює. Агент повторить очищення після наступного ходу."
  fi
}

authorize_mail() {
  [[ "$EMAIL_ENABLED" == "true" && -n "$PEER_EMAIL" ]] || {
    MAIL_READY=true
    return 0
  }

  if /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1
with timeout of 30 seconds
  tell application "Mail" to get version
end timeout
APPLESCRIPT
  then
    MAIL_READY=true
    /usr/bin/touch "$MAIL_AUTH_FILE"
    log "Доступ до Mail підтверджено"
    resolve_alerts "Email знову працює" "Доступ до Mail підтверджено." email
  else
    MAIL_READY=false
    /bin/rm -f "$MAIL_AUTH_FILE"
    log "Немає доступу до Mail; email вимкнено до перезапуску агента"
    raise_alert \
      email \
      "Email вимкнено" \
      "Обмін сейвами через iCloud працює. Перезапусти агент, щоб повторити авторизацію Mail."
    return 1
  fi
}

send_mail_message() {
  local subject="$1" content="$2"
  [[ "$MAIL_READY" == "true" ]] || return 1

  if ! /usr/bin/osascript - "$PEER_EMAIL" "$subject" "$content" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set recipientAddress to item 1 of argv
  set subjectText to item 2 of argv
  set bodyText to item 3 of argv

  tell application "Mail"
    set senderAddress to ""
    repeat with mailAccount in every account
      if enabled of mailAccount then
        set accountAddresses to email addresses of mailAccount
        set smtpAccount to delivery account of mailAccount
        if (count of accountAddresses) > 0 and smtpAccount is not missing value then
          if enabled of smtpAccount then
            set senderAddress to item 1 of accountAddresses
            exit repeat
          end if
        end if
      end if
    end repeat

    if senderAddress is "" then error "No enabled Mail account with an active SMTP server"
    set msg to make new outgoing message with properties {visible:false, subject:subjectText, content:bodyText & return}
    try
      set sender of msg to senderAddress
      tell msg
        make new to recipient at end of to recipients with properties {address:recipientAddress}
      end tell
      set sendSucceeded to send msg
      if sendSucceeded is not true then error "Mail returned false while sending"
    on error errorMessage number errorNumber
      try
        delete msg
      end try
      error errorMessage number errorNumber
    end try
  end tell
end run
APPLESCRIPT
  then
    MAIL_READY=false
    /bin/rm -f "$MAIL_AUTH_FILE"
    log "Mail повернув помилку; email вимкнено до перезапуску агента"
    raise_alert \
      email \
      "Email не надіслано" \
      "Обмін сейвами через iCloud працює. Повідом другого гравця вручну та перезапусти агент."
    return 1
  fi
}

send_email() {
  local content
  [[ "$EMAIL_ENABLED" == "true" ]] || return 0
  [[ -n "$PEER_EMAIL" ]] || return 0

  content="$SELF_NAME завершив хід у партії «$SAVE_NAME»."$'\n\n'"Сейв синхронізується через iCloud Drive. Відкрий VCMI та завантаж «$SAVE_NAME»."
  send_mail_message "Heroes 3 — твоя черга" "$content"
}

send_test_email() {
  send_mail_message \
    "VCMI Async — тест" \
    "Автоматизацію для $SELF_NAME налаштовано. Це тестовий лист."
}

save_files() {
  /usr/bin/find "$SAVE_DIR" -maxdepth 1 -type f \( \
    -name "${SAVE_NAME}.vcgm1" -o \
    -name "${SAVE_NAME}.vsgm1" -o \
    -name "${SAVE_NAME}.vlgm1" -o \
    -name "${SAVE_NAME}" \
  \) -print | /usr/bin/sort
}

file_signature() {
  /usr/bin/stat -f '%i:%m:%z' "$1" 2>/dev/null
}

save_signature() {
  local files file
  files="$(save_files)"
  [[ -n "$files" ]] || return 1

  while IFS= read -r file; do
    /usr/bin/stat -f '%i:%m:%z:%N' "$file" 2>/dev/null || return 1
  done <<< "$files"
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
  local expected_hash="$1"
  local staging tmpzip file copied_hash outgoing short_hash email_status="disabled"
  staging="$(/usr/bin/mktemp -d "$STATE_DIR/outgoing.XXXXXX")" || {
    raise_alert outgoing "Хід ще не передано" "Не вдалося створити staging. Агент повторить спробу автоматично."
    return 1
  }
  tmpzip="$(/usr/bin/mktemp "$STATE_DIR/outgoing.XXXXXX.zip")" || {
    raise_alert outgoing "Хід ще не передано" "Не вдалося створити тимчасовий ZIP. Агент повторить спробу автоматично."
    /bin/rm -rf "$staging"
    return 1
  }

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    /bin/cp -p "$file" "$staging/" || {
      log "Не вдалося підготувати сейв до відправлення: $file"
      raise_alert outgoing "Хід ще не передано" "Не вдалося підготувати ZIP. Агент повторить спробу автоматично."
      /bin/rm -rf "$staging" "$tmpzip"
      return 1
    }
    /usr/bin/cmp -s "$file" "$staging/${file:t}" || {
      log "Сейв змінився під час підготовки; відправлення буде повторено"
      /bin/rm -rf "$staging" "$tmpzip"
      return 1
    }
  done <<< "$(save_files)"

  if [[ -z "$(/usr/bin/find "$staging" -type f -maxdepth 1 -print -quit)" ]]; then
    log "Немає файлів сейва для відправлення"
    raise_alert outgoing "Хід ще не передано" "Не знайдено файлів сейва «$SAVE_NAME»."
    /bin/rm -rf "$staging" "$tmpzip"
    return 1
  fi

  copied_hash="$(bundle_hash 2>/dev/null || true)"
  if [[ "$copied_hash" != "$expected_hash" ]]; then
    log "Сейв змінився під час пакування; відправлення буде повторено"
    /bin/rm -rf "$staging" "$tmpzip"
    return 1
  fi

  /usr/bin/ditto -c -k --norsrc "$staging" "$tmpzip" || {
    log "Помилка створення ZIP"
    raise_alert outgoing "Хід ще не передано" "Не вдалося створити ZIP. Агент повторить спробу автоматично."
    /bin/rm -rf "$staging" "$tmpzip"
    return 1
  }

  short_hash="${expected_hash[1,12]}"
  outgoing="$ICLOUD_DIR/to-${PEER_ID}-${short_hash}.zip"
  if [[ ! -f "$outgoing" ]] && ! /bin/cp "$tmpzip" "$outgoing"; then
    log "Не вдалося записати ZIP в iCloud: $outgoing"
    raise_alert outgoing "Хід ще не передано" "Не вдалося записати сейв в iCloud. Агент повторює спробу автоматично."
    /bin/rm -rf "$staging" "$tmpzip"
    return 1
  fi

  /bin/rm -rf "$staging" "$tmpzip"
  log "Сейв відправлено: $outgoing"
  resolve_alerts "" "" outgoing
  cleanup_outgoing || true

  # Даємо iCloud трохи часу почати завантаження, потім надсилаємо email.
  /bin/sleep 10
  if [[ "$EMAIL_ENABLED" == "true" && -n "$PEER_EMAIL" ]]; then
    if send_email; then
      email_status="sent"
    else
      email_status="failed"
      log "Mail не зміг надіслати email"
    fi
  fi

  case "$email_status" in
    sent)
      notify_user "VCMI Async — хід передано" "$PEER_NAME отримає повідомлення" "Сейв синхронізовано через iCloud, email надіслано."
      ;;
    failed)
      # send_mail_message уже показав дедуплікований alert.
      ;;
    *)
      notify_user "VCMI Async — хід передано" "Сейв уже в iCloud" "Можна закривати Mac."
      ;;
  esac
}

is_expected_save_name() {
  case "$1" in
    "$SAVE_NAME"|\
    "${SAVE_NAME}.vcgm1"|\
    "${SAVE_NAME}.vsgm1"|\
    "${SAVE_NAME}.vlgm1")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

restore_backup() {
  local backup="$1"
  local file

  /bin/rm -f \
    "$SAVE_DIR/${SAVE_NAME}.vcgm1" \
    "$SAVE_DIR/${SAVE_NAME}.vsgm1" \
    "$SAVE_DIR/${SAVE_NAME}.vlgm1" \
    "$SAVE_DIR/${SAVE_NAME}"

  while IFS= read -r -d '' file; do
    /bin/cp -p "$file" "$SAVE_DIR/" || return 1
  done < <(/usr/bin/find "$backup" -maxdepth 1 -type f -print0)
}

import_incoming() {
  local archive_hash stable_hash final_hash old_hash staging install_staging
  local backup imported_hash file relative_name found_expected incoming_signature incoming
  local -a incoming_files
  incoming_files=("$ICLOUD_DIR"/to-${SELF_ID}-*.zip(.omN))
  if (( ${#incoming_files} == 0 )); then
    LAST_SEEN_INCOMING_SIGNATURE=""
    return 0
  fi
  incoming="$incoming_files[1]"

  incoming_signature="$(file_signature "$incoming")" || return 0
  [[ "$incoming_signature" != "$LAST_SEEN_INCOMING_SIGNATURE" ]] || return 0

  archive_hash="$(/usr/bin/shasum -a 256 "$incoming" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 0
  [[ -n "$archive_hash" ]] || return 0
  old_hash="$(cat "$LAST_INCOMING_FILE" 2>/dev/null || true)"
  if [[ "$archive_hash" == "$old_hash" ]]; then
    LAST_SEEN_INCOMING_SIGNATURE="$incoming_signature"
    return 0
  fi

  # Перевіряємо, що весь архів, а не лише його розмір, уже стабільний.
  /bin/sleep "$STABILITY_SECONDS"
  stable_hash="$(/usr/bin/shasum -a 256 "$incoming" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 0
  [[ -n "$stable_hash" && "$stable_hash" == "$archive_hash" ]] || return 0
  archive_hash="$stable_hash"
  if ! /usr/bin/unzip -tqq "$incoming" >/dev/null 2>&1; then
    raise_alert incoming "Новий сейв не імпортовано" "Вхідний ZIP пошкоджений або не завантажився повністю. Локальний сейв не змінено."
    LAST_SEEN_INCOMING_SIGNATURE="$incoming_signature"
    return 0
  fi

  staging="$(/usr/bin/mktemp -d "$STATE_DIR/incoming.XXXXXX")" || {
    raise_alert incoming "Новий сейв не імпортовано" "Не вдалося створити staging. Локальний сейв не змінено."
    return 1
  }
  /usr/bin/ditto -x -k "$incoming" "$staging" || {
    log "Не вдалося розпакувати вхідний сейв"
    raise_alert incoming "Новий сейв не імпортовано" "Не вдалося розпакувати ZIP. Локальний сейв не змінено."
    /bin/rm -rf "$staging"
    return 1
  }

  # Відхиляємо порожні архіви, каталоги, посилання та сторонні файли.
  found_expected=false
  while IFS= read -r -d '' file; do
    relative_name="${file#$staging/}"
    if [[ "$relative_name" == "$file" || "$relative_name" == */* || ! -f "$file" || -L "$file" ]] ||
       ! is_expected_save_name "$relative_name"; then
      log "Вхідний ZIP містить недозволений об’єкт: $relative_name"
      raise_alert incoming "Новий сейв не імпортовано" "ZIP містить неочікувані файли. Локальний сейв не змінено."
      LAST_SEEN_INCOMING_SIGNATURE="$incoming_signature"
      /bin/rm -rf "$staging"
      return 1
    fi
    found_expected=true
  done < <(/usr/bin/find "$staging" -mindepth 1 -print0)

  if [[ "$found_expected" != "true" ]]; then
    log "Вхідний ZIP не містить сейва $SAVE_NAME"
    raise_alert incoming "Новий сейв не імпортовано" "ZIP не містить сейва «$SAVE_NAME». Локальний сейв не змінено."
    LAST_SEEN_INCOMING_SIGNATURE="$incoming_signature"
    /bin/rm -rf "$staging"
    return 1
  fi

  # Переконуємося, що під час розпакування iCloud не замінив архів.
  final_hash="$(/usr/bin/shasum -a 256 "$incoming" 2>/dev/null | /usr/bin/awk '{print $1}')" || {
    /bin/rm -rf "$staging"
    return 0
  }
  if [[ "$final_hash" != "$archive_hash" ]]; then
    log "Вхідний ZIP змінився під час розпакування; імпорт буде повторено"
    /bin/rm -rf "$staging"
    return 0
  fi

  # Спочатку готуємо повну нову копію на тому самому диску, що й SAVE_DIR.
  install_staging="$(/usr/bin/mktemp -d "$SAVE_DIR/.vcmi-async.XXXXXX")" || {
    log "Не вдалося створити staging у папці сейвів"
    raise_alert import "Помилка імпорту сейва" "Не вдалося підготувати папку сейвів. Локальний сейв не змінено."
    /bin/rm -rf "$staging"
    return 1
  }
  while IFS= read -r -d '' file; do
    /bin/cp -p "$file" "$install_staging/" || {
      log "Не вдалося підготувати вхідний сейв: $file"
      raise_alert import "Помилка імпорту сейва" "Не вдалося підготувати новий сейв. Локальний сейв не змінено."
      /bin/rm -rf "$staging" "$install_staging"
      return 1
    }
  done < <(/usr/bin/find "$staging" -maxdepth 1 -type f -print0)

  backup="$(/usr/bin/mktemp -d "$STATE_DIR/backup-$(date '+%Y%m%d-%H%M%S').XXXXXX")" || {
    log "Не вдалося створити каталог backup"
    raise_alert import "Помилка імпорту сейва" "Не вдалося створити backup. Локальний сейв не змінено."
    /bin/rm -rf "$staging" "$install_staging"
    return 1
  }
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    /bin/cp -p "$file" "$backup/" || {
      log "Не вдалося створити backup: $file"
      raise_alert import "Помилка імпорту сейва" "Не вдалося створити backup. Локальний сейв не змінено."
      /bin/rm -rf "$staging" "$install_staging" "$backup"
      return 1
    }
  done <<< "$(save_files)"

  # Замінюємо лише файли цієї партії; при помилці відновлюємо backup.
  if ! /bin/rm -f \
    "$SAVE_DIR/${SAVE_NAME}.vcgm1" \
    "$SAVE_DIR/${SAVE_NAME}.vsgm1" \
    "$SAVE_DIR/${SAVE_NAME}.vlgm1" \
    "$SAVE_DIR/${SAVE_NAME}"; then
    log "Не вдалося прибрати попередню версію сейва"
    if restore_backup "$backup"; then
      raise_alert import "Помилка імпорту сейва" "Попередній сейв відновлено. Новий сейв не імпортовано."
    else
      log "КРИТИЧНО: не вдалося відновити сейв із $backup"
      raise_alert critical "Критична помилка імпорту" "Не відкривай VCMI. Перевір logs/agent.log."
    fi
    /bin/rm -rf "$staging" "$install_staging"
    return 1
  fi

  while IFS= read -r -d '' file; do
    if ! /bin/mv -f "$file" "$SAVE_DIR/"; then
      log "Не вдалося встановити вхідний сейв; відновлюємо backup"
      if restore_backup "$backup"; then
        raise_alert import "Помилка імпорту сейва" "Попередній сейв відновлено. Новий сейв не імпортовано."
      else
        log "КРИТИЧНО: не вдалося відновити сейв із $backup"
        raise_alert critical "Критична помилка імпорту" "Не відкривай VCMI. Перевір logs/agent.log."
      fi
      /bin/rm -rf "$staging" "$install_staging"
      return 1
    fi
  done < <(/usr/bin/find "$install_staging" -maxdepth 1 -type f -print0)
  /bin/rm -rf "$staging" "$install_staging"

  imported_hash="$(bundle_hash 2>/dev/null || true)"
  if [[ -z "$imported_hash" ]]; then
    log "Імпортований сейв не пройшов фінальну перевірку; відновлюємо backup"
    if restore_backup "$backup"; then
      raise_alert import "Помилка імпорту сейва" "Фінальна перевірка не пройдена. Попередній сейв відновлено."
    else
      log "КРИТИЧНО: не вдалося відновити сейв із $backup"
      raise_alert critical "Критична помилка імпорту" "Не відкривай VCMI. Перевір logs/agent.log."
    fi
    return 1
  fi

  print -r -- "$archive_hash" > "$LAST_INCOMING_FILE"
  print -r -- "$imported_hash" > "$LAST_LOCAL_FILE"
  LAST_SEEN_INCOMING_SIGNATURE="$(file_signature "$incoming" || print -r -- "$incoming_signature")"

  log "Вхідний сейв імпортовано"
  resolve_alerts "" "" incoming import critical
  notify_local
}

main_loop() {
  local current_hash previous_hash stable_hash
  local current_signature handled_signature stable_signature
  local loop_count=0

  housekeeping
  log "Агент запущено. SAVE_DIR=$SAVE_DIR; ICLOUD_DIR=$ICLOUD_DIR"
  authorize_mail || true

  # Перший запуск: поточний локальний сейв стає базовим і не відправляється сам.
  if [[ ! -f "$LAST_LOCAL_FILE" ]]; then
    local initial_hash
    initial_hash="$(bundle_hash 2>/dev/null || true)"
    [[ -n "$initial_hash" ]] && print -r -- "$initial_hash" > "$LAST_LOCAL_FILE"
  fi
  current_signature="$(save_signature 2>/dev/null || true)"
  current_hash="$(bundle_hash 2>/dev/null || true)"
  previous_hash="$(cat "$LAST_LOCAL_FILE" 2>/dev/null || true)"
  [[ -n "$current_hash" && "$current_hash" == "$previous_hash" ]] \
    && handled_signature="$current_signature" \
    || handled_signature=""

  while true; do
    import_incoming

    if [[ -f "$MAIL_TEST_REQUEST" ]]; then
      send_test_email && log "Тестовий email надіслано"
      /bin/rm -f "$MAIL_TEST_REQUEST"
    fi

    current_signature="$(save_signature 2>/dev/null || true)"
    if [[ "$current_signature" != "$handled_signature" ]]; then
      current_hash="$(bundle_hash 2>/dev/null || true)"
      previous_hash="$(cat "$LAST_LOCAL_FILE" 2>/dev/null || true)"

      if [[ -n "$current_hash" && "$current_hash" == "$previous_hash" ]]; then
        handled_signature="$current_signature"
      elif [[ -n "$current_hash" ]]; then
        /bin/sleep "$STABILITY_SECONDS"
        stable_signature="$(save_signature 2>/dev/null || true)"
        stable_hash="$(bundle_hash 2>/dev/null || true)"

        if [[ "$stable_signature" == "$current_signature" && "$stable_hash" == "$current_hash" ]]; then
          if package_and_send "$stable_hash"; then
            print -r -- "$stable_hash" > "$LAST_LOCAL_FILE"
            handled_signature="$stable_signature"
          fi
        fi
      fi
    fi

    if (( ++loop_count >= 360 )); then
      housekeeping
      loop_count=0
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

if [[ "$IS_UPDATE" == "false" ]]; then
  /bin/rm -f "$STATE_DIR/mail-automation-ok" "$STATE_DIR/send-test-email"
fi
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
      echo "Запит передано фоновому агенту."
    fi
  else
    echo "Доступ до Mail не підтверджено. Email поки вимкнено, але iCloud-синхронізація працює."
    echo "Щоб спробувати ще раз, перезапусти агент і натисни Allow."
  fi
fi

echo
echo "Готово."
