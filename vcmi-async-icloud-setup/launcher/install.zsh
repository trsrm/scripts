#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_NAME="Грати VCMI Async.app"
SOURCE_APP="$SCRIPT_DIR/$APP_NAME"
APPLICATIONS_DIR="${VCMI_ASYNC_APPLICATIONS_DIR:-$HOME/Applications}"
TARGET_APP="$APPLICATIONS_DIR/$APP_NAME"
LEGACY_APP_PATH="${VCMI_ASYNC_LEGACY_APP_PATH:-$HOME/Library/Application Support/VCMIAsync/$APP_NAME}"
STAGING_ROOT=""
BACKUP_APP="$APPLICATIONS_DIR/.vcmi-async-launcher.backup.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cleanup() {
  [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]] && /bin/rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

if [[ ! -d "$SOURCE_APP" ]]; then
  print -u2 -r -- "Не знайдено готовий launcher: $SOURCE_APP"
  exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict "$SOURCE_APP"; then
  print -u2 -r -- "Підпис готового launcher пошкоджений"
  exit 1
fi

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$SOURCE_APP" >/dev/null 2>&1 || true
  [[ -e "$LEGACY_APP_PATH" || -L "$LEGACY_APP_PATH" ]] && \
    "$LSREGISTER" -u "$LEGACY_APP_PATH" >/dev/null 2>&1 || true
fi
if [[ -L "$LEGACY_APP_PATH" ]]; then
  /bin/rm "$LEGACY_APP_PATH"
fi

/bin/mkdir -p "$APPLICATIONS_DIR"
STAGING_ROOT="$(/usr/bin/mktemp -d "$APPLICATIONS_DIR/.vcmi-async-launcher.XXXXXX")"
STAGED_APP="$STAGING_ROOT/$APP_NAME"
/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

if [[ -e "$BACKUP_APP" || -L "$BACKUP_APP" ]]; then
  /bin/rm -rf "$BACKUP_APP"
fi
if [[ -e "$TARGET_APP" || -L "$TARGET_APP" ]]; then
  /bin/mv "$TARGET_APP" "$BACKUP_APP"
fi

if ! /bin/mv "$STAGED_APP" "$TARGET_APP"; then
  [[ -e "$BACKUP_APP" || -L "$BACKUP_APP" ]] && /bin/mv "$BACKUP_APP" "$TARGET_APP"
  print -u2 -r -- "Не вдалося встановити launcher у $APPLICATIONS_DIR"
  exit 1
fi
/bin/rm -rf "$BACKUP_APP"

[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$TARGET_APP" >/dev/null 2>&1 || true

print -r -- "$TARGET_APP"
