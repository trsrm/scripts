#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_NAME="Грати VCMI Async.app"
APP_PATH="$SCRIPT_DIR/$APP_NAME"
ICON_SOURCE="$SCRIPT_DIR/AppIcon.png"
STAGING_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vcmi-launcher-build.XXXXXX")"
STAGED_APP="$STAGING_ROOT/$APP_NAME"
ICONSET="$STAGING_ROOT/AppIcon.iconset"
DESIGNATED_REQUIREMENT='=designated => identifier "dev.romaniv.vcmi-async-launcher" and info[CFBundleExecutable] = "vcmi-async-launcher"'

cleanup() {
  /bin/rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

if [[ ! -s "$ICON_SOURCE" ]]; then
  print -u2 -r -- "Не знайдено launcher/AppIcon.png"
  exit 1
fi

/bin/mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$ICONSET"
/bin/cp "$SCRIPT_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"

for size scale in \
  16 1 16 2 \
  32 1 32 2 \
  128 1 128 2 \
  256 1 256 2 \
  512 1 512 2; do
  pixels=$(( size * scale ))
  suffix=""
  (( scale == 2 )) && suffix="@2x"
  /usr/bin/sips -z "$pixels" "$pixels" "$ICON_SOURCE" \
    --out "$ICONSET/icon_${size}x${size}${suffix}.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" \
  -o "$STAGED_APP/Contents/Resources/AppIcon.icns"

/usr/bin/xcrun swiftc \
  -O \
  -target arm64-apple-macosx13.0 \
  "$SCRIPT_DIR/vcmi-async-launcher.swift" \
  -o "$STAGED_APP/Contents/MacOS/vcmi-async-launcher"

/usr/bin/codesign \
  --force \
  --deep \
  --sign - \
  --identifier dev.romaniv.vcmi-async-launcher \
  --requirements "$DESIGNATED_REQUIREMENT" \
  "$STAGED_APP"

if [[ -e "$APP_PATH" ]]; then
  /bin/rm -rf "$APP_PATH"
fi
/bin/mv "$STAGED_APP" "$APP_PATH"

print -r -- "Створено: $APP_PATH"
