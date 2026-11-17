#!/usr/bin/env bash
# Local checks of the container lib and chomik-dl-settings: no docker,
# systemd, network or installed app needed. Run as root or a normal user:
#   bash proxmox/tests/lib-tests.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MISC="$HERE/../misc"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
check() { # description, command...
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
eq() { # description, expected, actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
fails() { ! "$@" 2>/dev/null; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export CHOMIKDL_ENV="$T/chomik-dl.env"
export CD_LOCK_FILE="$T/lock/maintenance.lock"
export CHOMIKDL_LIB="$MISC/chomik-dl-lib.sh"

if [[ ! -f "$CHOMIKDL_LIB" ]]; then
  bad "lib exists ($CHOMIKDL_LIB)"
  echo
  echo "lib tests: $PASS passed, $FAIL failed"
  exit 1
fi
# shellcheck source=../misc/chomik-dl-lib.sh
. "$CHOMIKDL_LIB"

# --- quoting -----------------------------------------------------------------
roundtrip() { eq "quote/unquote round trip: [$1]" "$1" "$(cd_unquote "$(cd_quote "$1")")"; }
roundtrip "p'a\"\$b#c\\ d=e"
roundtrip "  spaces around  "
roundtrip "plain"
roundtrip ""

# --- settings get/set --------------------------------------------------------
: >"$CHOMIKDL_ENV"
pw="p'a\"\$b#c\\ d=e"
check "set password with special characters" cd_settings_set CHOMIKUJ_PASSWORD "$pw"
eq "get password back byte for byte" "$pw" "$(cd_settings_get CHOMIKUJ_PASSWORD)"
check "set login with surrounding spaces" cd_settings_set CHOMIKUJ_LOGIN "  user  "
eq "get login with surrounding spaces" "  user  " "$(cd_settings_get CHOMIKUJ_LOGIN)"
check "set login again (replace)" cd_settings_set CHOMIKUJ_LOGIN "user2"
eq "login replaced, one line" "1" "$(grep -c '^CHOMIKUJ_LOGIN=' "$CHOMIKDL_ENV")"
eq "file mode 640" "640" "$(stat -c %a "$CHOMIKDL_ENV")"

rm -f "$T/pwned"
evil="\$(touch $T/pwned)\`touch $T/pwned\`"
check "set a command-looking value" cd_settings_set CHOMIKUJ_PASSWORD "$evil"
eq "command-looking value stays literal" "$evil" "$(cd_settings_get CHOMIKUJ_PASSWORD)"
check "value was never executed" test ! -e "$T/pwned"

check "newline rejected" fails cd_settings_set CHOMIKUJ_LOGIN $'a\nb'
check "carriage return rejected" fails cd_settings_set CHOMIKUJ_LOGIN $'a\rb'
eq "rejected value not written" "user2" "$(cd_settings_get CHOMIKUJ_LOGIN)"
check "unknown key rejected" fails cd_settings_set SOMETHING_ELSE x
check "unknown key not written" fails grep -q '^SOMETHING_ELSE=' "$CHOMIKDL_ENV"
check "get of a missing key fails" fails cd_settings_get PUBLIC_URL

# --- validation --------------------------------------------------------------
check "empty login rejected" fails cd_validate CHOMIKUJ_LOGIN ""
check "empty password rejected" fails cd_validate CHOMIKUJ_PASSWORD ""
msg="$(cd_validate PUBLIC_URL ftp://x 2>&1)"
check "PUBLIC_URL=ftp://x rejected" test $? -ne 0
check "message names the key" grep -q PUBLIC_URL <<<"$msg"
check "PUBLIC_URL with trailing slash rejected" fails cd_validate PUBLIC_URL http://h:8080/
check "PUBLIC_URL http://h:8080 accepted" cd_validate PUBLIC_URL http://h:8080
check "PUBLIC_URL https with path accepted" cd_validate PUBLIC_URL https://dl.example.com/chomik
check "ALLOWED_HOSTS=a.lan,b.lan accepted" cd_validate ALLOWED_HOSTS a.lan,b.lan
check "ALLOWED_HOSTS empty accepted" cd_validate ALLOWED_HOSTS ""
check "ALLOWED_HOSTS with a URL rejected" fails cd_validate ALLOWED_HOSTS http://a.lan
check "MIN_JOB_GAP_SECONDS=-1 rejected" fails cd_validate MIN_JOB_GAP_SECONDS -1
check "MIN_JOB_GAP_SECONDS=abc rejected" fails cd_validate MIN_JOB_GAP_SECONDS abc
check "MIN_JOB_GAP_SECONDS=20 accepted" cd_validate MIN_JOB_GAP_SECONDS 20
check "HUMAN_PAUSE_MIN=0.5 accepted" cd_validate HUMAN_PAUSE_MIN 0.5
check "set HUMAN_PAUSE_MAX=4" cd_settings_set HUMAN_PAUSE_MAX 4
msg="$(cd_validate HUMAN_PAUSE_MIN 5 2>&1)"
check "HUMAN_PAUSE_MIN=5 with MAX 4 rejected" test $? -ne 0
check "pause message names the key" grep -q HUMAN_PAUSE_MIN <<<"$msg"
check "HUMAN_PAUSE_MIN=4 with MAX 4 accepted" cd_validate HUMAN_PAUSE_MIN 4
check "set HUMAN_PAUSE_MIN=2" cd_settings_set HUMAN_PAUSE_MIN 2
check "HUMAN_PAUSE_MAX=1 with MIN 2 rejected" fails cd_validate HUMAN_PAUSE_MAX 1
check "CHOMIKDL_CHANNEL=beta rejected" fails cd_validate CHOMIKDL_CHANNEL beta
check "CHOMIKDL_CHANNEL=releases accepted" cd_validate CHOMIKDL_CHANNEL releases
check "DOWNLOAD_REQUIRE_MOUNT=maybe rejected" fails cd_validate DOWNLOAD_REQUIRE_MOUNT maybe
check "DATA_DIR relative rejected" fails cd_validate DATA_DIR var/lib

# --- fixed settings ----------------------------------------------------------
check "cd_write_fixed_settings" cd_write_fixed_settings
eq "fixed DATA_DIR" "/var/lib/chomik-dl" "$(cd_settings_get DATA_DIR)"
eq "fixed DOWNLOAD_DIR" "/data" "$(cd_settings_get DOWNLOAD_DIR)"
eq "fixed DOWNLOAD_REQUIRE_MOUNT" "true" "$(cd_settings_get DOWNLOAD_REQUIRE_MOUNT)"
eq "fixed PLAYWRIGHT_BROWSERS_PATH" "/opt/chomik-dl-browsers" "$(cd_settings_get PLAYWRIGHT_BROWSERS_PATH)"
eq "fixed HEADLESS" "true" "$(cd_settings_get HEADLESS)"
eq "user settings kept" "user2" "$(cd_settings_get CHOMIKUJ_LOGIN)"

# --- cd_collect_settings -----------------------------------------------------
collect() { (cd_collect_settings); } # own shell: fresh answer descriptor
export CHOMIKDL_ENV="$T/collect.env"
: >"$CHOMIKDL_ENV"
out="$(CHOMIKDL_UNATTENDED=1 CHOMIKDL_LOGIN=tester CHOMIKDL_PASSWORD="$pw" collect 2>&1)"
eq "unattended collect with credentials exits 0" 0 "$?"
eq "unattended: login from CHOMIKDL_LOGIN" "tester" "$(cd_settings_get CHOMIKUJ_LOGIN)"
eq "unattended: password from CHOMIKDL_PASSWORD" "$pw" "$(cd_settings_get CHOMIKUJ_PASSWORD)"
check "unattended: password not in output" fails grep -qF "$pw" <<<"$out"
check "unattended: default PUBLIC_URL" grep -qE "^PUBLIC_URL='http://[^/]+:8080'$" "$CHOMIKDL_ENV"
eq "unattended: default gap" "20" "$(cd_settings_get MIN_JOB_GAP_SECONDS)"
eq "unattended: default channel" "main" "$(cd_settings_get CHOMIKDL_CHANNEL)"
check "credentials present" cd_has_credentials

: >"$CHOMIKDL_ENV"
cd_write_fixed_settings
out="$(CHOMIKDL_UNATTENDED=1 collect 2>&1)"
eq "unattended collect without credentials exits 0" 0 "$?"
check "without credentials: says to run chomik-dl-settings" grep -q 'chomik-dl-settings' <<<"$out"
check "without credentials: no login line" fails grep -q '^CHOMIKUJ_LOGIN=' "$CHOMIKDL_ENV"
check "without credentials: cd_has_credentials fails" fails cd_has_credentials
check "without credentials: rest written" grep -q '^MIN_JOB_GAP_SECONDS=' "$CHOMIKDL_ENV"
eq "collect keeps fixed settings" "/data" "$(cd_settings_get DOWNLOAD_DIR)"

# Answers: login, password, PUBLIC_URL, ALLOWED_HOSTS, pacing? y, gap,
# MIN 5 / MAX 3 (inconsistent, asked again), MIN 0.5 / MAX 2, channel.
printf '%s\n' me "$pw" http://dl.lan:8080 dl.lan y 30 5 3 0.5 2 releases >"$T/answers"
CHOMIKDL_ANSWERS="$T/answers" collect >/dev/null 2>&1
eq "answered collect exits 0" 0 "$?"
eq "answered: login" "me" "$(cd_settings_get CHOMIKUJ_LOGIN)"
eq "answered: password" "$pw" "$(cd_settings_get CHOMIKUJ_PASSWORD)"
eq "answered: PUBLIC_URL" "http://dl.lan:8080" "$(cd_settings_get PUBLIC_URL)"
eq "answered: ALLOWED_HOSTS" "dl.lan" "$(cd_settings_get ALLOWED_HOSTS)"
eq "answered: gap" "30" "$(cd_settings_get MIN_JOB_GAP_SECONDS)"
eq "answered: pauses asked again after MIN > MAX" "0.5 2" "$(cd_settings_get HUMAN_PAUSE_MIN) $(cd_settings_get HUMAN_PAUSE_MAX)"
eq "answered: channel" "releases" "$(cd_settings_get CHOMIKDL_CHANNEL)"

# Input ends after MIN 5 (like Cancel/timeout on the MAX question): the
# install must go on with a consistent pair, never fail.
: >"$CHOMIKDL_ENV"
printf '%s\n' me "$pw" http://dl.lan:8080 "" y 30 5 >"$T/answers"
CHOMIKDL_ANSWERS="$T/answers" collect >/dev/null 2>&1
eq "cancelled MAX question: collect exits 0" 0 "$?"
eq "cancelled MAX question: default pair kept" "1.0 4.0" "$(cd_settings_get HUMAN_PAUSE_MIN) $(cd_settings_get HUMAN_PAUSE_MAX)"
eq "cancelled MAX question: other answers saved" "me 30" "$(cd_settings_get CHOMIKUJ_LOGIN) $(cd_settings_get MIN_JOB_GAP_SECONDS)"
cd_settings_set HUMAN_PAUSE_MIN 0.5 && cd_settings_set HUMAN_PAUSE_MAX 2
printf '%s\n' "" "" "" "" y "" 9 >"$T/answers"
CHOMIKDL_ANSWERS="$T/answers" collect >/dev/null 2>&1
eq "cancelled MAX question on a re-run: exits 0" 0 "$?"
eq "cancelled MAX question on a re-run: previous pair kept" "0.5 2" "$(cd_settings_get HUMAN_PAUSE_MIN) $(cd_settings_get HUMAN_PAUSE_MAX)"

# --- releases channel without releases or tags --------------------------------
if command -v python3 >/dev/null; then
  # No releases/latest file: the fake API answers 404 like GitHub does.
  mkdir -p "$T/api/repos/o/none" "$T/api/repos/o/tagged"
  echo '[]' >"$T/api/repos/o/none/tags"
  echo '[{"name": "v1.2"}]' >"$T/api/repos/o/tagged/tags"
  port=$((20000 + RANDOM % 20000))
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$T/api" >/dev/null 2>&1 &
  srv=$!
  for _ in $(seq 50); do curl -fs "http://127.0.0.1:$port/repos/o/none/tags" >/dev/null 2>&1 && break; sleep 0.1; done
  export CHOMIKDL_GITHUB_API="http://127.0.0.1:$port"
  ref="$(CHOMIKDL_REPO=o/none cd_latest_ref releases 2>&1)"
  eq "no release or tag: cd_latest_ref status 2" 2 "$?"
  eq "no release or tag: prints nothing" "" "$ref"
  eq "no release: newest tag used" "v1.2" "$(CHOMIKDL_REPO=o/tagged cd_latest_ref releases 2>&1)"
  mkdir -p "$T/app"
  echo abc123 >"$T/version"
  cd_settings_set CHOMIKDL_CHANNEL releases
  out="$(CHOMIKDL_REPO=o/none CD_APP_DIR="$T/app" CD_VERSION_FILE="$T/version" cd_update 2>&1)"
  eq "update without a release exits 0" 0 "$?"
  eq "update without a release says so" "No release yet; staying on abc123." "$out"
  eq "update without a release keeps the version" "abc123" "$(cat "$T/version")"
  kill "$srv" 2>/dev/null
  wait "$srv" 2>/dev/null
  unset CHOMIKDL_GITHUB_API
else
  bad "python3 needed for the fake GitHub API"
fi

# --- chomik-dl-settings argument parsing --------------------------------------
SETTINGS=("$MISC/chomik-dl-settings")
help="$(bash "${SETTINGS[@]}" --help 2>&1)"
eq "--help exits 0" 0 "$?"
check "--help mentions --set KEY -" grep -qF -- '--set KEY -' <<<"$help"
bash "${SETTINGS[@]}" --set CHOMIKUJ_LOGIN >/dev/null 2>&1
eq "--set with missing value exits 2" 2 "$?"
bash "${SETTINGS[@]}" --set >/dev/null 2>&1
eq "--set without arguments exits 2" 2 "$?"
bash "${SETTINGS[@]}" --get >/dev/null 2>&1
eq "--get without key exits 2" 2 "$?"
bash "${SETTINGS[@]}" --bogus >/dev/null 2>&1
eq "unknown option exits 2" 2 "$?"
eq "--get prints a value" "me" "$(bash "${SETTINGS[@]}" --get CHOMIKUJ_LOGIN 2>&1)"
bash "${SETTINGS[@]}" --get NOPE >/dev/null 2>&1
eq "--get unknown key exits 1" 1 "$?"

echo
echo "lib tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
