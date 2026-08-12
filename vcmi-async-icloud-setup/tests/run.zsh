#!/bin/zsh
set -u

ROOT_DIR="${0:A:h:h}"
AGENT="$ROOT_DIR/vcmi-async.zsh"
INSTALLER="$ROOT_DIR/install-vcmi-async.command"
TEST_ROOT="$(/usr/bin/mktemp -d /tmp/vcmi-async-tests.XXXXXX)"
[[ "${KEEP_TEST_ROOT:-false}" == "true" ]] || trap '/bin/rm -rf "$TEST_ROOT"' EXIT

typeset -i tests=0 failures=0

pass() { print -r -- "PASS $1"; }
fail() { print -u2 -r -- "FAIL $1"; (( failures += 1 )); }

check() {
  local name="$1"
  shift
  (( tests += 1 ))
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

check_not() {
  local name="$1"
  shift
  (( tests += 1 ))
  if "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi
}

check_equal() {
  local name="$1" expected="$2" actual="$3"
  (( tests += 1 ))
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name (expected=$expected actual=$actual)"
  fi
}

setup_game() {
  local name="$1" save_name="${2:-async-game}"
  CASE_ROOT="$TEST_ROOT/$name"
  TEST_HOME="$CASE_ROOT/home"
  SAVE_DIR="$CASE_ROOT/saves"
  ICLOUD_DIR="$CASE_ROOT/icloud"
  CONFIG_DIR="$TEST_HOME/Library/Application Support/VCMIAsync"
  STATE_DIR="$CONFIG_DIR/state"
  /bin/mkdir -p "$SAVE_DIR" "$ICLOUD_DIR" "$CONFIG_DIR"

  {
    print -r -- "SAVE_DIR=${(q)SAVE_DIR}"
    print -r -- "ICLOUD_DIR=${(q)ICLOUD_DIR}"
    print -r -- "SAVE_NAME=${(q)save_name}"
    print -r -- "SELF_ID=taras"
    print -r -- "SELF_NAME=Taras"
    print -r -- "PEER_ID=vitalii"
    print -r -- "PEER_NAME=Vitalii"
    print -r -- "PEER_EMAIL=''"
    print -r -- "EMAIL_ENABLED=false"
  } > "$CONFIG_DIR/config.zsh"
}

run_agent() {
  HOME="$TEST_HOME" VCMI_ASYNC_ADAPTER=local /bin/zsh "$AGENT"
}

make_save_zip() {
  local output="$1" content="$2" name="${3:-async-game.vsgm1}"
  local source_dir
  source_dir="$(/usr/bin/mktemp -d "$TEST_ROOT/zip.XXXXXX")" || return 1
  print -r -- "$content" > "$source_dir/$name"
  /usr/bin/ditto -c -k --norsrc "$source_dir" "$output"
  /bin/rm -rf "$source_dir"
}

file_hash() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

setup_game main
print -r -- baseline > "$SAVE_DIR/async-game.vsgm1"
check "first run succeeds" run_agent
check_not "baseline is not published" test -f "$ICLOUD_DIR/to-vitalii.zip"
check "baseline hash is recorded" test -s "$STATE_DIR/last-local-hash"
check_not "missing incoming ZIP is not an error" test -f "$STATE_DIR/alert-finder"

print -r -- turn-one > "$SAVE_DIR/async-game.vsgm1"
check "first changed check succeeds" run_agent
check "changed save becomes pending" test -s "$STATE_DIR/pending-local-hash"
check_not "pending save is not published early" test -f "$ICLOUD_DIR/to-vitalii.zip"
check "second stable check succeeds" run_agent
check "stable ZIP is published" test -f "$ICLOUD_DIR/to-vitalii.zip"
check "published ZIP is valid" /usr/bin/unzip -tqq "$ICLOUD_DIR/to-vitalii.zip"
check_not "pending state clears after publish" test -f "$STATE_DIR/pending-local-hash"
check_not "own outgoing ZIP is not an identity mismatch" test -f "$STATE_DIR/alert-identity"

first_zip_hash="$(file_hash "$ICLOUD_DIR/to-vitalii.zip")"
print -r -- transient > "$SAVE_DIR/async-game.vsgm1"
check "new transient hash becomes pending" run_agent
print -r -- turn-two > "$SAVE_DIR/async-game.vsgm1"
check "changing pending save is not published" run_agent
check_equal "stable ZIP remains unchanged" "$first_zip_hash" "$(file_hash "$ICLOUD_DIR/to-vitalii.zip")"
check "new value publishes after next check" run_agent
second_zip_hash="$(file_hash "$ICLOUD_DIR/to-vitalii.zip")"
check_not "stable ZIP is replaced" test "$first_zip_hash" = "$second_zip_hash"
outgoing_files=("$ICLOUD_DIR"/to-vitalii*.zip(N))
check_equal "only one outgoing ZIP exists" 1 "${#outgoing_files}"

make_save_zip "$ICLOUD_DIR/to-taras.zip" incoming-one
sent_before="$(rg -c 'Сейв відправлено:' "$CONFIG_DIR/logs/agent.log")"
check "incoming turn imports" run_agent
check_equal "incoming save replaces local save" incoming-one "$(<"$SAVE_DIR/async-game.vsgm1")"
check "incoming archive hash is recorded" test -s "$STATE_DIR/last-incoming-archive-hash"
check_equal \
  "imported save is not sent back" \
  "$sent_before" \
  "$(rg -c 'Сейв відправлено:' "$CONFIG_DIR/logs/agent.log")"
backups=("$STATE_DIR"/backup-*(/N))
check_equal "import creates one backup" 1 "${#backups}"

notifications_before="$(wc -l < "$STATE_DIR/test-notifications")"
check "unchanged incoming ZIP is ignored" run_agent
backups=("$STATE_DIR"/backup-*(/N))
check_equal "unchanged ZIP creates no backup" 1 "${#backups}"
check_equal \
  "unchanged ZIP creates no notification" \
  "$notifications_before" \
  "$(wc -l < "$STATE_DIR/test-notifications")"

print -r -- broken > "$ICLOUD_DIR/to-taras.zip"
check "broken ZIP is retryable" run_agent
check_equal "broken ZIP leaves save intact" incoming-one "$(<"$SAVE_DIR/async-game.vsgm1")"
check "broken ZIP raises visible alert" test -f "$STATE_DIR/alert-incoming"

make_save_zip "$ICLOUD_DIR/to-taras.zip" incoming-two
check "valid retry imports" run_agent
check_equal "valid retry replaces save" incoming-two "$(<"$SAVE_DIR/async-game.vsgm1")"
check_not "recovery clears incoming alert" test -f "$STATE_DIR/alert-incoming"

make_save_zip "$ICLOUD_DIR/to-taras.zip" unexpected unexpected.txt
check "unexpected ZIP is rejected" run_agent
check_equal "unexpected ZIP leaves save intact" incoming-two "$(<"$SAVE_DIR/async-game.vsgm1")"

/bin/rm -f "$ICLOUD_DIR/to-taras.zip"
/bin/dd if=/dev/zero of="$CONFIG_DIR/logs/agent.log" bs=1048576 count=1 2>/dev/null
print x >> "$CONFIG_DIR/logs/agent.log"
check "large log rotates" run_agent
check "rotated log is retained" test -f "$CONFIG_DIR/logs/agent.log.1"

for i in {1..25}; do
  /bin/mkdir -p "$STATE_DIR/backup-old-$i"
done
check "housekeeping succeeds" run_agent
backups=("$STATE_DIR"/backup-*(/N))
check_equal "only twenty backups remain" 20 "${#backups}"

setup_game migration
print -r -- existing-turn > "$SAVE_DIR/async-game.vsgm1"
/bin/mkdir -p "$STATE_DIR"
print -r -- old-unversioned-hash > "$STATE_DIR/last-local-hash"
check "old hash migrates safely" run_agent
check_not "migration does not publish existing save" test -f "$ICLOUD_DIR/to-vitalii.zip"
check "migrated local hash is versioned" /usr/bin/grep -q '^v2:' "$STATE_DIR/last-local-hash"

setup_game email
{
  print -r -- "PEER_EMAIL=peer@example.test"
  print -r -- "EMAIL_ENABLED=true"
} >> "$CONFIG_DIR/config.zsh"
print -r -- baseline > "$SAVE_DIR/async-game.vsgm1"
check "scheduled process prepares Mail permission" run_agent
check "Mail permission marker persists between runs" test -f "$STATE_DIR/mail-automation-ok"
print -r -- email-turn > "$SAVE_DIR/async-game.vsgm1"
check "email turn becomes pending" run_agent
check "next process publishes email turn" run_agent
check_equal "one email is sent" 1 "$(rg -c '^peer@example\.test\|' "$STATE_DIR/test-mails")"
check "unchanged save remains quiet" run_agent
check_equal "email is not duplicated" 1 "$(rg -c '^peer@example\.test\|' "$STATE_DIR/test-mails")"

setup_game identity-mismatch
{
  print -r -- "SELF_ID=vitalik"
  print -r -- "PEER_ID=taras"
} >> "$CONFIG_DIR/config.zsh"
print -r -- baseline > "$SAVE_DIR/async-game.vsgm1"
make_save_zip "$ICLOUD_DIR/to-vitalii.zip" incoming-turn
check "mismatched recipient ID is detected" run_agent
check "mismatched recipient ID raises visible alert" test -f "$STATE_DIR/alert-identity"
check "identity alert names expected and actual ZIP" \
  /usr/bin/grep -q 'to-vitalik.zip.*to-vitalii.zip' "$STATE_DIR/test-notifications"
check_not "mismatched recipient ZIP is not imported" \
  /usr/bin/grep -q '^incoming-turn$' "$SAVE_DIR/async-game.vsgm1"
identity_notifications="$(wc -l < "$STATE_DIR/test-notifications")"
check "repeated mismatch check succeeds" run_agent
check_equal "identity alert is deduplicated" \
  "$identity_notifications" "$(wc -l < "$STATE_DIR/test-notifications")"
print -r -- "SELF_ID=vitalii" >> "$CONFIG_DIR/config.zsh"
check "corrected recipient ID imports waiting turn" run_agent
check_equal "corrected recipient ZIP replaces save" \
  incoming-turn "$(<"$SAVE_DIR/async-game.vsgm1")"
check_not "corrected recipient ID clears alert" test -f "$STATE_DIR/alert-identity"

setup_game invalid '*'
check_not "invalid save name is rejected" run_agent

check "agent syntax" /bin/zsh -n "$AGENT"
check "installer syntax" /bin/zsh -n "$INSTALLER"
check "installer schedules one-minute runs" \
  /usr/bin/grep -A1 -q '<key>StartInterval</key>' "$INSTALLER"
check_not "agent has no permanent loop" /usr/bin/grep -q 'while true' "$AGENT"
check_not "plist has no KeepAlive" /usr/bin/grep -q '<key>KeepAlive</key>' "$INSTALLER"
check_not "versioned ZIP cleanup is gone" \
  /usr/bin/grep -E -q 'CLEANUP_|finder_cleanup|cleanup_outgoing' "$AGENT" "$INSTALLER"
check_not "obsolete timing config is gone" \
  /usr/bin/grep -E -q 'POLL_SECONDS|STABILITY_SECONDS|INCOMING_POLL_SECONDS|POST_PUBLISH_DELAY_SECONDS' \
  "$AGENT" "$INSTALLER"

print -r -- "$tests tests, $failures failures"
(( failures == 0 ))
