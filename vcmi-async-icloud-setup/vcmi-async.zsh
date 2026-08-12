#!/bin/zsh
set -u

CONFIG_DIR="$HOME/Library/Application Support/VCMIAsync"
source "$CONFIG_DIR/config.zsh"

EMAIL_ENABLED="${EMAIL_ENABLED:-true}"
VCMI_ASYNC_ADAPTER="${VCMI_ASYNC_ADAPTER:-finder}"

STATE_DIR="$CONFIG_DIR/state"
LOG_DIR="$CONFIG_DIR/logs"
LAST_LOCAL_FILE="$STATE_DIR/last-local-hash"
PENDING_LOCAL_FILE="$STATE_DIR/pending-local-hash"
LAST_INCOMING_FILE="$STATE_DIR/last-incoming-archive-hash"
INCOMING_CACHE_DIR="$STATE_DIR/incoming-cache"
OUTGOING_CACHE_DIR="$STATE_DIR/outgoing-cache"
FINDER_AUTH_FILE="$STATE_DIR/finder-automation-ok"
MAIL_AUTH_FILE="$STATE_DIR/mail-automation-ok"
MAIL_TEST_REQUEST="$STATE_DIR/send-test-email"
MAIL_READY=false

validate_config() {
  if [[ -z "$SAVE_NAME" || "$SAVE_NAME" == "." || "$SAVE_NAME" == ".." ||
    "$SAVE_NAME" == */* || "$SAVE_NAME" == *:* || "$SAVE_NAME" == *'\'* ||
    "$SAVE_NAME" == *'*'* || "$SAVE_NAME" == *'?'* ||
    "$SAVE_NAME" == *'['* || "$SAVE_NAME" == *']'* ||
    "$SAVE_NAME" == *$'\n'* || "$SAVE_NAME" == *$'\r'* ]]; then
    print -u2 -r -- "Некоректна назва сейва: $SAVE_NAME"
    return 1
  fi
  if [[ ! "$SELF_ID" =~ '^[a-z0-9_-]+$' || ! "$PEER_ID" =~ '^[a-z0-9_-]+$' ||
    "$SELF_ID" == "$PEER_ID" ]]; then
    print -u2 -r -- "Некоректні ID гравців"
    return 1
  fi
  if [[ ! -d "$SAVE_DIR" || ! -d "$ICLOUD_DIR" ]]; then
    print -u2 -r -- "Папки VCMI Saves та iCloud мають існувати"
    return 1
  fi
  if [[ "$VCMI_ASYNC_ADAPTER" != "finder" && "$VCMI_ASYNC_ADAPTER" != "local" ]]; then
    print -u2 -r -- "Некоректний transport adapter"
    return 1
  fi
}

validate_config || exit 1
/bin/mkdir -p "$STATE_DIR" "$LOG_DIR" "$INCOMING_CACHE_DIR" "$OUTGOING_CACHE_DIR"

log() {
  print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_DIR/agent.log"
}

write_state() {
  local file="$1" value="$2" tmp
  tmp="$(/usr/bin/mktemp "$STATE_DIR/.state.XXXXXX")" || return 1
  if print -r -- "$value" > "$tmp" && /bin/mv -f "$tmp" "$file"; then
    return 0
  fi
  /bin/rm -f "$tmp"
  return 1
}

read_state() {
  local value=""
  [[ -f "$1" ]] && IFS= read -r value < "$1"
  print -r -- "$value"
}

notify_user() {
  if [[ "$VCMI_ASYNC_ADAPTER" == "local" ]]; then
    print -r -- "$1|$2|$3" >> "$STATE_DIR/test-notifications"
    return
  fi

  /usr/bin/osascript - "$1" "$2" "$3" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv)
end run
APPLESCRIPT
}

raise_alert() {
  local key="$1" subtitle="$2" message="$3" marker="$STATE_DIR/alert-$1"
  [[ -f "$marker" ]] && return
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
  [[ -f "$file" ]] || return
  size="$(/usr/bin/stat -f '%z' "$file" 2>/dev/null)" || return
  (( size < 1048576 )) && return

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
  for candidate in "$STATE_DIR"/incoming.*(N) "$STATE_DIR"/outgoing.*(N) \
    "$STATE_DIR"/.state.*(N) "$INCOMING_CACHE_DIR"/*(N) \
    "$OUTGOING_CACHE_DIR"/*(N) "$SAVE_DIR"/.vcmi-async.*(N); do
    modified="$(/usr/bin/stat -f '%m' "$candidate" 2>/dev/null)" || continue
    (( now - modified > 86400 )) && /bin/rm -rf "$candidate"
  done
}

save_files() {
  local suffix file
  for suffix in .vcgm1 .vsgm1 .vlgm1 ""; do
    file="$SAVE_DIR/${SAVE_NAME}${suffix}"
    [[ -f "$file" ]] && print -r -- "$file"
  done
}

bundle_hash_at() {
  local dir="$1" suffix file hash manifest=""
  for suffix in .vcgm1 .vsgm1 .vlgm1 ""; do
    file="$dir/${SAVE_NAME}${suffix}"
    [[ -f "$file" ]] || continue
    hash="$(/usr/bin/shasum -a 256 "$file" 2>/dev/null | /usr/bin/awk '{print $1}')" || return 1
    [[ -n "$hash" ]] || return 1
    manifest+="${file:t}:$hash"$'\n'
  done
  [[ -n "$manifest" ]] || return 1
  print -rn -- "$manifest" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

finder_stage_incoming() {
  local stable_name="to-${SELF_ID}.zip" outgoing_name="to-${PEER_ID}.zip"

  if [[ "$VCMI_ASYNC_ADAPTER" == "local" ]]; then
    local candidate
    if [[ -f "$ICLOUD_DIR/$stable_name" ]]; then
      /bin/cp -f "$ICLOUD_DIR/$stable_name" "$INCOMING_CACHE_DIR/" || return 1
      print -r -- "$stable_name"
      return
    fi
    for candidate in "$ICLOUD_DIR"/to-*.zip(.N); do
      [[ "${candidate:t}" == "$outgoing_name" ]] && continue
      print -r -- "IDENTITY_MISMATCH:${candidate:t}"
      return
    done
    return
  fi

  /usr/bin/osascript - "$ICLOUD_DIR" "$INCOMING_CACHE_DIR" \
    "$stable_name" "$outgoing_name" <<'APPLESCRIPT' 2>/dev/null
on run argv
  set sourceFolder to POSIX file (item 1 of argv) as alias
  set destinationFolder to POSIX file (item 2 of argv) as alias
  set stableName to item 3 of argv
  set outgoingName to item 4 of argv
  set sourceFile to missing value
  set mismatchedName to ""

  with timeout of 60 seconds
    tell application "Finder" to set candidates to every file in sourceFolder
    repeat with candidate in candidates
      tell application "Finder" to set candidateName to name of candidate
      if candidateName is stableName then
        set sourceFile to candidate
        exit repeat
      end if
      if candidateName starts with "to-" and candidateName ends with ".zip" and candidateName is not outgoingName then
        set mismatchedName to candidateName
      end if
    end repeat

    if sourceFile is missing value then
      if mismatchedName is not "" then return "IDENTITY_MISMATCH:" & mismatchedName
      return ""
    end if
    tell application "Finder"
      set sourceName to name of sourceFile
      duplicate sourceFile to destinationFolder with replacing
    end tell
    return sourceName
  end timeout
end run
APPLESCRIPT
}

finder_publish() {
  local source="$1"
  if [[ "$VCMI_ASYNC_ADAPTER" == "local" ]]; then
    /bin/cp -f "$source" "$ICLOUD_DIR/"
    return
  fi

  /usr/bin/osascript - "$source" "$ICLOUD_DIR" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set sourceFile to POSIX file (item 1 of argv) as alias
  set destinationFolder to POSIX file (item 2 of argv) as alias
  with timeout of 60 seconds
    tell application "Finder" to duplicate sourceFile to destinationFolder with replacing
  end timeout
end run
APPLESCRIPT
}

stage_incoming() {
  local incoming_name target actual_name expected_name="to-${SELF_ID}.zip"
  incoming_name="$(finder_stage_incoming)" || {
    /bin/rm -f "$FINDER_AUTH_FILE"
    log "Finder не зміг отримати вхідний ZIP"
    raise_alert finder "Не вдалося прочитати iCloud" "Агент повторить спробу за хвилину. Локальний сейв не змінено."
    return 1
  }

  /usr/bin/touch "$FINDER_AUTH_FILE"
  resolve_alerts "iCloud знову доступний" "Обмін сейвами відновлено." finder
  if [[ "$incoming_name" == IDENTITY_MISMATCH:* ]]; then
    actual_name="${incoming_name#IDENTITY_MISMATCH:}"
    raise_alert identity "Перевір SELF_ID" \
      "Агент шукає «$expected_name», але в iCloud є «$actual_name». Запусти інсталятор і виправ SELF_ID."
    return 0
  fi
  [[ -n "$incoming_name" && "$incoming_name" != */* ]] || return 0

  [[ "$incoming_name" == "$expected_name" ]] || return 1
  resolve_alerts "SELF_ID виправлено" "Агент знову бачить адресований тобі ZIP." identity

  target="$INCOMING_CACHE_DIR/$incoming_name"
  [[ -f "$target" ]] || return 1
  print -r -- "$target"
}

prepare_mail() {
  [[ "$EMAIL_ENABLED" == "true" && -n "$PEER_EMAIL" ]] || return 0
  if [[ "$VCMI_ASYNC_ADAPTER" == "local" || -f "$MAIL_AUTH_FILE" ]]; then
    MAIL_READY=true
    /usr/bin/touch "$MAIL_AUTH_FILE"
    return
  fi

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
    /bin/rm -f "$MAIL_AUTH_FILE"
    raise_alert email "Email вимкнено" "iCloud працює. Дозволь керування Mail; агент повторить спробу за хвилину."
  fi
}

send_mail_message() {
  local subject="$1" content="$2"
  [[ "$MAIL_READY" == "true" ]] || return 1

  if [[ "$VCMI_ASYNC_ADAPTER" == "local" ]]; then
    print -r -- "$PEER_EMAIL|$subject|$content" >> "$STATE_DIR/test-mails"
    return
  fi

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
    raise_alert email "Email не надіслано" "Сейв уже в iCloud. Повідом другого гравця вручну."
    return 1
  fi
}

send_email() {
  local content
  [[ "$EMAIL_ENABLED" == "true" && -n "$PEER_EMAIL" ]] || return 1
  content="$SELF_NAME завершив хід у партії «$SAVE_NAME»."$'\n\n'
  content+="Сейв синхронізується через iCloud Drive. Відкрий VCMI та завантаж «$SAVE_NAME»."
  send_mail_message "Heroes 3 — твоя черга" "$content"
}

validate_archive_entries() {
  local archive="$1" entries entry
  local -i count=0
  local -A seen
  entries="$(/usr/bin/unzip -Z1 "$archive" 2>/dev/null)" || return 1
  [[ -n "$entries" ]] || return 1

  while IFS= read -r entry; do
    case "$entry" in
      ("$SAVE_NAME"|"${SAVE_NAME}.vcgm1"|"${SAVE_NAME}.vsgm1"|"${SAVE_NAME}.vlgm1") ;;
      (*) return 1 ;;
    esac
    [[ "$entry" != */* && -z "${seen[$entry]-}" ]] || return 1
    seen[$entry]=1
    (( count += 1 ))
  done <<< "$entries"
  (( count > 0 ))
}

restore_backup() {
  local backup="$1" file
  /bin/rm -f \
    "$SAVE_DIR/${SAVE_NAME}.vcgm1" "$SAVE_DIR/${SAVE_NAME}.vsgm1" \
    "$SAVE_DIR/${SAVE_NAME}.vlgm1" "$SAVE_DIR/${SAVE_NAME}"
  while IFS= read -r -d '' file; do
    /bin/cp -p "$file" "$SAVE_DIR/" || return 1
  done < <(/usr/bin/find "$backup" -maxdepth 1 -type f -print0)
}

record_import_state() {
  write_state "$LAST_LOCAL_FILE" "v2:$2" &&
    write_state "$LAST_INCOMING_FILE" "$1"
}

import_incoming() {
  local incoming archive_hash old_hash staging install_staging backup
  local file relative_name imported_hash found_expected=false

  incoming="$(stage_incoming)" || return 1
  [[ -n "$incoming" ]] || return 0
  archive_hash="$(/usr/bin/shasum -a 256 "$incoming" 2>/dev/null | /usr/bin/awk '{print $1}')" || {
    /bin/rm -f "$incoming"
    return
  }
  old_hash="$(read_state "$LAST_INCOMING_FILE")"
  if [[ -n "$archive_hash" && "$archive_hash" == "$old_hash" ]]; then
    /bin/rm -f "$incoming"
    return
  fi

  if ! /usr/bin/unzip -tqq "$incoming" >/dev/null 2>&1 ||
     ! validate_archive_entries "$incoming"; then
    log "Вхідний ZIP пошкоджений або містить неочікувані файли"
    raise_alert incoming "Новий сейв не імпортовано" "ZIP пошкоджений або некоректний. Локальний сейв не змінено."
    /bin/rm -f "$incoming"
    return
  fi

  staging="$(/usr/bin/mktemp -d "$STATE_DIR/incoming.XXXXXX")" || {
    raise_alert incoming "Новий сейв не імпортовано" "Не вдалося створити staging. Локальний сейв не змінено."
    /bin/rm -f "$incoming"
    return
  }
  if ! /usr/bin/ditto -x -k "$incoming" "$staging"; then
    raise_alert incoming "Новий сейв не імпортовано" "Не вдалося розпакувати ZIP. Локальний сейв не змінено."
    /bin/rm -rf "$incoming" "$staging"
    return
  fi

  while IFS= read -r -d '' file; do
    relative_name="${file#$staging/}"
    case "$relative_name" in
      ("$SAVE_NAME"|"${SAVE_NAME}.vcgm1"|"${SAVE_NAME}.vsgm1"|"${SAVE_NAME}.vlgm1")
        [[ -f "$file" && ! -L "$file" ]] || found_expected=invalid
        ;;
      (*) found_expected=invalid ;;
    esac
    [[ "$found_expected" != "invalid" ]] || break
    found_expected=true
  done < <(/usr/bin/find "$staging" -mindepth 1 -print0)

  if [[ "$found_expected" != "true" ]]; then
    raise_alert incoming "Новий сейв не імпортовано" "ZIP містить неочікувані об’єкти. Локальний сейв не змінено."
    /bin/rm -rf "$incoming" "$staging"
    return
  fi

  install_staging="$(/usr/bin/mktemp -d "$SAVE_DIR/.vcmi-async.XXXXXX")" || {
    raise_alert import "Помилка імпорту" "Не вдалося підготувати папку сейвів. Локальний сейв не змінено."
    /bin/rm -rf "$incoming" "$staging"
    return
  }
  while IFS= read -r -d '' file; do
    /bin/cp -p "$file" "$install_staging/" || {
      raise_alert import "Помилка імпорту" "Не вдалося підготувати новий сейв. Локальний сейв не змінено."
      /bin/rm -rf "$incoming" "$staging" "$install_staging"
      return
    }
  done < <(/usr/bin/find "$staging" -maxdepth 1 -type f -print0)

  backup="$(/usr/bin/mktemp -d "$STATE_DIR/backup-$(/bin/date '+%Y%m%d-%H%M%S').XXXXXX")" || {
    raise_alert import "Помилка імпорту" "Не вдалося створити backup. Локальний сейв не змінено."
    /bin/rm -rf "$incoming" "$staging" "$install_staging"
    return
  }
  while IFS= read -r file; do
    /bin/cp -p "$file" "$backup/" || {
      raise_alert import "Помилка імпорту" "Не вдалося створити backup. Локальний сейв не змінено."
      /bin/rm -rf "$incoming" "$staging" "$install_staging" "$backup"
      return
    }
  done <<< "$(save_files)"

  if ! /bin/rm -f \
    "$SAVE_DIR/${SAVE_NAME}.vcgm1" "$SAVE_DIR/${SAVE_NAME}.vsgm1" \
    "$SAVE_DIR/${SAVE_NAME}.vlgm1" "$SAVE_DIR/${SAVE_NAME}"; then
    restore_backup "$backup" || raise_alert critical "Критична помилка" "Не відкривай VCMI. Перевір backup і logs/agent.log."
    raise_alert import "Помилка імпорту" "Попередній сейв відновлено."
    /bin/rm -rf "$incoming" "$staging" "$install_staging"
    return
  fi

  while IFS= read -r -d '' file; do
    if ! /bin/mv -f "$file" "$SAVE_DIR/"; then
      restore_backup "$backup" || raise_alert critical "Критична помилка" "Не відкривай VCMI. Перевір backup і logs/agent.log."
      raise_alert import "Помилка імпорту" "Попередній сейв відновлено."
      /bin/rm -rf "$incoming" "$staging" "$install_staging"
      return
    fi
  done < <(/usr/bin/find "$install_staging" -maxdepth 1 -type f -print0)
  /bin/rm -rf "$staging" "$install_staging"

  imported_hash="$(bundle_hash_at "$SAVE_DIR" 2>/dev/null || true)"
  if [[ -z "$imported_hash" ]]; then
    restore_backup "$backup" || raise_alert critical "Критична помилка" "Не відкривай VCMI. Перевір backup і logs/agent.log."
    raise_alert import "Помилка імпорту" "Фінальна перевірка не пройдена. Попередній сейв відновлено."
    /bin/rm -f "$incoming"
    return
  fi

  if ! record_import_state "$archive_hash" "$imported_hash"; then
    log "КРИТИЧНО: не вдалося записати стан імпорту"
    raise_alert critical "Критична помилка" "Не відкривай VCMI. Не вдалося зберегти стан імпорту."
    /bin/rm -f "$incoming"
    return 2
  fi

  /bin/rm -f "$incoming" "$PENDING_LOCAL_FILE"
  resolve_alerts "" "" incoming import critical
  log "Вхідний сейв імпортовано"
  notify_user "Heroes 3 — твоя черга" "$PEER_NAME завершив хід" \
    "Сейв «$SAVE_NAME» уже завантажено. Можна відкривати VCMI."
}

package_and_send() {
  local expected_hash="$1" staging tmpzip staged_hash outgoing_name outgoing_file
  staging="$(/usr/bin/mktemp -d "$STATE_DIR/outgoing.XXXXXX")" || {
    raise_alert outgoing "Хід ще не передано" "Не вдалося створити staging. Агент повторить спробу за хвилину."
    return 1
  }
  tmpzip="$(/usr/bin/mktemp "$STATE_DIR/outgoing.XXXXXX.zip")" || {
    /bin/rm -rf "$staging"
    return 1
  }

  while IFS= read -r file; do
    /bin/cp -p "$file" "$staging/" || {
      /bin/rm -rf "$staging" "$tmpzip"
      return 1
    }
  done <<< "$(save_files)"

  staged_hash="$(bundle_hash_at "$staging" 2>/dev/null || true)"
  if [[ "$staged_hash" != "$expected_hash" ]]; then
    log "Сейв змінився під час підготовки; спробу відкладено"
    /bin/rm -rf "$staging" "$tmpzip"
    return 1
  fi

  if ! /usr/bin/ditto -c -k --norsrc "$staging" "$tmpzip" ||
     ! /usr/bin/unzip -tqq "$tmpzip" >/dev/null 2>&1 ||
     ! validate_archive_entries "$tmpzip"; then
    raise_alert outgoing "Хід ще не передано" "Не вдалося створити коректний ZIP. Агент повторить спробу за хвилину."
    /bin/rm -rf "$staging" "$tmpzip"
    return 1
  fi

  outgoing_name="to-${PEER_ID}.zip"
  outgoing_file="$OUTGOING_CACHE_DIR/$outgoing_name"
  if ! /bin/cp -p "$tmpzip" "$outgoing_file" ||
     ! /usr/bin/cmp -s "$tmpzip" "$outgoing_file" ||
     ! finder_publish "$outgoing_file"; then
    /bin/rm -rf "$staging" "$tmpzip" "$outgoing_file"
    raise_alert outgoing "Хід ще не передано" "Не вдалося записати ZIP в iCloud. Агент повторить спробу за хвилину."
    return 1
  fi
  /bin/rm -rf "$staging" "$tmpzip" "$outgoing_file"

  log "Сейв відправлено: $ICLOUD_DIR/$outgoing_name"
  resolve_alerts "" "" outgoing
  if send_email; then
    notify_user "VCMI Async — хід передано" "$PEER_NAME отримає повідомлення" \
      "Сейв синхронізовано через iCloud, email надіслано."
  elif [[ "$EMAIL_ENABLED" != "true" || -z "$PEER_EMAIL" ]]; then
    notify_user "VCMI Async — хід передано" "Сейв уже в iCloud" "Можна закривати Mac."
  fi
}

process_outgoing() {
  local current_hash current_state last_hash pending_hash
  current_hash="$(bundle_hash_at "$SAVE_DIR" 2>/dev/null || true)"
  [[ -n "$current_hash" ]] || return 0
  current_state="v2:$current_hash"
  last_hash="$(read_state "$LAST_LOCAL_FILE")"

  if [[ "$last_hash" != v2:* ]]; then
    write_state "$LAST_LOCAL_FILE" "$current_state" || \
      raise_alert state "Не вдалося зберегти стан" "Перевір права на VCMIAsync/state."
    /bin/rm -f "$PENDING_LOCAL_FILE"
    log "Поточний локальний сейв прийнято як базовий"
    return
  fi
  if [[ "$current_state" == "$last_hash" ]]; then
    /bin/rm -f "$PENDING_LOCAL_FILE"
    return
  fi

  pending_hash="$(read_state "$PENDING_LOCAL_FILE")"
  if [[ "$pending_hash" != "$current_state" ]]; then
    write_state "$PENDING_LOCAL_FILE" "$current_state" || \
      raise_alert state "Не вдалося зберегти стан" "Перевір права на VCMIAsync/state."
    return
  fi

  if package_and_send "$current_hash"; then
    if write_state "$LAST_LOCAL_FILE" "$current_state"; then
      /bin/rm -f "$PENDING_LOCAL_FILE"
      resolve_alerts "" "" state
    else
      raise_alert state "Не вдалося зберегти стан" "Хід передано, але email може повторитися."
    fi
  fi
}

run_once() {
  local import_status
  housekeeping
  prepare_mail

  import_incoming
  import_status=$?
  (( import_status == 2 )) && return

  if [[ -f "$MAIL_TEST_REQUEST" ]]; then
    send_mail_message "VCMI Async — тест" \
      "Автоматизацію для $SELF_NAME налаштовано. Це тестовий лист." &&
      log "Тестовий email надіслано"
    /bin/rm -f "$MAIL_TEST_REQUEST"
  fi

  process_outgoing
}

run_once
